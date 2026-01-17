# Security Policy and Threat Analysis

## Executive Summary

Peyk-D is a DNS-based messaging system for restricted networks. This document describes the current security posture, vulnerabilities, and hardening recommendations.

Current Status: Production-ready with critical fixes needed

---

## Threat Model

### System Assumptions

Network Environment:
- TCP/HTTP blocked or monitored
- UDP/DNS (port 53) generally allowed
- Server accessible via authoritative DNS domain
- Clients have IPv4/IPv6 connectivity

Threat Actors:
1. Passive DPI Firewall: can see query metadata (timing, size, sender/receiver IDs)
2. Active MITM: can drop or modify packets
3. Compromised Server: can read plaintext in memory
4. Code Repository Exposure: source code becomes public

---

## What Peyk-D Protects

| Threat | Protection | Strength |
|--------|-----------|----------|
| Message Content Eavesdropping | AES-256-GCM encryption | High |
| Message Tampering | AES-GCM authentication tag (built-in) | High |
| Passive Network Analysis | Protocol obscuration via DNS | Medium |
| Simple Replay (within retention window) | Content-hash dedup prevents duplicate delivery | Medium |
| Full Replay Protection | Not provided (requires server-side nonce tracking) | None |
| Duplicate Detection | Content-hash deduplication | High |
| Sender Spoofing | Not implemented (see vulnerabilities) | None |

---

## What Peyk-D Does Not Protect

| Threat | Reason | Mitigation |
|--------|--------|-----------|
| Traffic Analysis | Query timing/size/frequency visible | Add noise queries, randomize intervals |
| Sender/Receiver Identification | IDs in DNS labels | Use VPN/Tor if anonymity needed |
| Domain Identification | DNS server IP identifies service | Domain rotation, proxy through CDN |
| Message Ordering Inference | Sequence of queries visible | Randomize query order |
| Large Message Fingerprinting | Same large message yields same chunk count | Add padding |
| Brute-force Passphrase | Weak passphrase vulnerable | Use strong passphrase (16+ chars) |
| Anonymity | Not designed for this | Use Tor + Peyk-D for dual protection |
| Server Compromise | Plaintext in memory | Physical security/trusted operators |

---

## CRITICAL Vulnerabilities

### CVE-001: Hardcoded Credentials

Severity: CRITICAL (CVSS 9.8)  
Status: UNFIXED

Description:
Domain and passphrase are required for operation. They are now supplied via
environment variables on the server and build-time defines on the client.
This prevents leaking secrets through Git, but secrets are still recoverable
from client binaries.

```dart
// client_mobile/lib/core/protocol.dart
static const String passphrase =
    String.fromEnvironment('PEYK_PASSPHRASE', defaultValue: '');
```

Impact:
- GitHub exposure = instant compromise
- Any compiled binary leak = all messages decryptable
- Historical messages retroactively compromised

Timeline to Fix: IMMEDIATE (before production)

Remediation:

1) Server:
```bash
# Create .env.example (for git)
PEYK_DOMAIN=your-domain.ir
PEYK_PASSPHRASE=<generate-strong-passphrase>

# Create .env (NOT committed)
# .gitignore: .env
```

```go
// main.go
import "os"

var (
  BASE_DOMAIN = os.Getenv("PEYK_DOMAIN")
  PASSPHRASE  = os.Getenv("PEYK_PASSPHRASE")
)

func init() {
  if BASE_DOMAIN == "" || PASSPHRASE == "" {
    log.Fatal("PEYK_DOMAIN and PEYK_PASSPHRASE env vars required")
  }
}
```

2) Client (build-time config):
```bash
flutter run \
  --dart-define=PEYK_DOMAIN=example.com \
  --dart-define=PEYK_PASSPHRASE=strong-secret-here \
  --dart-define=PEYK_DIRECT_SERVER_IP=198.51.100.10
```
This keeps secrets out of Git, but does not prevent extraction from the binary.

3) Simulator:
```bash
PEYK_DOMAIN=example.com \
PEYK_PASSPHRASE=strong-secret-here \
go run simulator.go
```

---

### CVE-002: Missing Sender Authentication

Severity: HIGH (CVSS 7.5)  
Status: UNFIXED

Description:
Any client knowing the receiver ID can send messages without proving identity.

Attack Scenario:
```
1) Attacker monitors DNS: alice -> bob (pattern recognized)
2) Attacker crafts: 1-1-mid-attacker-bob-"Send money"
3) Server stores, bob receives message from "attacker" (displayed as alice)
4) Social engineering succeeds
```

Impact:
- Message spoofing
- Impersonation attacks
- Trust undermined

Important Caveat:
HMAC with a shared passphrase provides integrity only, not sender authentication.
- All clients sharing the same passphrase can generate valid HMACs
- Cannot distinguish between Alice and Eve (same key)
- Prevents tampering in transit, but not spoofing
- True sender authentication requires per-contact keys (ECDH) or asymmetric signing (Ed25519)

Interim Fix (Integrity Only):

```dart
import 'dart:convert';
import 'package:crypto/crypto.dart';

String computeHmac(String plaintext, String passphrase) {
  final keyBytes = utf8.encode(passphrase);
  final msgBytes = utf8.encode(plaintext);
  final hmac = Hmac(sha256, keyBytes);
  final digest = hmac.convert(msgBytes);
  return digest.toString().substring(0, 16);
}

// TX: sign plaintext before encryption
Future<Uint8List> encryptWithIntegrityCheck(String plaintext) async {
  final sig = computeHmac(plaintext, PeykProtocol.passphrase);
  final signed = "$plaintext;$sig";
  return await PeykCrypto.encrypt(signed);
}

// RX: verify integrity after decryption
Future<String> decryptAndVerifyIntegrity(Uint8List encrypted) async {
  final signed = await PeykCrypto.decrypt(encrypted);
  final parts = signed.split(';');
  if (parts.length != 2) {
    return "WARN: no integrity tag (possible tampering or old message)";
  }
  final plaintext = parts[0];
  final receivedSig = parts[1];
  final expectedSig = computeHmac(plaintext, PeykProtocol.passphrase);
  if (receivedSig != expectedSig) {
    return "ERROR: integrity check failed (message modified in transit)";
  }
  return plaintext;
}
```

Limitation: this does NOT prevent sender spoofing.

---

### CVE-003: DNS Amplification Attack

Severity: HIGH (CVSS 7.1)  
Status: UNFIXED

Description:
Server responds with large AAAA record sets. If attacker spoofs source IP, server becomes a DDoS amplifier.

Attack Flow:
```
1) Attacker source-spoofs: query from victim.com (actually attacker)
2) Peyk server responds: many AAAA RRs = large UDP response
3) Victim receives DDoS traffic
4) Amplification: 1 query -> many responses
```

Impact:
- Victim ISP overwhelmed
- Peyk-D server listed as DDoS source
- Service shutdown risk

Remediation (Token Bucket + Cleanup):
Note: a simple time.Time map leaks memory. Cleanup is required.

```go
// main.go
const (
  RATE_LIMIT_PER_IP = 100
  CLEANUP_INTERVAL = 1 * time.Minute
)

type RateLimiter struct {
  lastQuery time.Time
  tokens    float64
}

var (
  rateLimiters = make(map[string]*RateLimiter)
  rateLimitMu  sync.Mutex
)

func checkRateLimit(ip string) bool {
  rateLimitMu.Lock()
  defer rateLimitMu.Unlock()

  now := time.Now()
  limiter, exists := rateLimiters[ip]
  if !exists {
    limiter = &RateLimiter{lastQuery: now, tokens: float64(RATE_LIMIT_PER_IP)}
    rateLimiters[ip] = limiter
  }

  elapsed := now.Sub(limiter.lastQuery).Seconds()
  limiter.tokens += elapsed * float64(RATE_LIMIT_PER_IP)
  if limiter.tokens > float64(RATE_LIMIT_PER_IP) {
    limiter.tokens = float64(RATE_LIMIT_PER_IP)
  }
  limiter.lastQuery = now

  if limiter.tokens >= 1.0 {
    limiter.tokens--
    return true
  }
  return false
}

func cleanupRateLimiters() {
  ticker := time.NewTicker(CLEANUP_INTERVAL)
  defer ticker.Stop()
  for range ticker.C {
    rateLimitMu.Lock()
    now := time.Now()
    for ip, limiter := range rateLimiters {
      if now.Sub(limiter.lastQuery) > 5*time.Minute {
        delete(rateLimiters, ip)
      }
    }
    rateLimitMu.Unlock()
  }
}
```

Additional mitigation: cap response size (max RR count) to reduce amplification factor.

---

## HIGH Severity Issues

### CVE-004: Unbounded Goroutine Spawning

Severity: HIGH (CVSS 6.5)

Issue:
```go
for {
  go handlePacket(conn, remoteAddr, pkt) // No limit
}
```

Fix:
```go
const MAX_CONCURRENT_HANDLERS = 1000
var handlerSem = make(chan struct{}, MAX_CONCURRENT_HANDLERS)

for {
  handlerSem <- struct{}{}
  go func() {
    defer func() { <-handlerSem }()
    handlePacket(conn, remoteAddr, pkt)
  }()
}
```

---

### CVE-005: ACK2 Replay Attack

Severity: MEDIUM (CVSS 5.3)

Issue:
An attacker can replay a captured ACK2 to prematurely stop resends.

Why CRC32 Nonce is Weak:
```go
expectedNonce := fmt.Sprintf("%04x", crc32.ChecksumIEEE([]byte(keyHash)))
// CRC is predictable and not cryptographic
```

Better Fix (HMAC + Timestamp in ACK2):

Idea:
- ACK2 carries a timestamp and HMAC
- Server accepts only if timestamp is within a short window
- Still not full authentication if passphrase is shared globally

Example:
```
ack2-<sid>-<tot>-<mid>-<ts>-<mac>
mac = HMAC(passphrase, sid|tot|mid|ts)
```

Server validation:
- parse fields
- reject if ts older than allowed window (e.g. 10 minutes)
- recompute HMAC and compare using hmac.Equal

---

### CVE-006: Message ID Collision

Severity: MEDIUM (CVSS 4.7)

Issue:
5-char Message IDs (32^5 = 33M) are collision-prone at volume.

Impact if Collision Occurs:
```
User A sends: msg(mid=abc12, tot=3) -> stored as sid:abc12:3
User B sends: msg(mid=abc12, tot=2) -> overwrites same key
Result: mixed frames and corrupted payloads
```

Fix:
```go
// Increase ID length from 5 to 8 chars
func generateID() string {
  const chars = "abcdefghijklmnopqrstuvwxyz234567"
  const idLength = 8
  b := make([]byte, idLength)
  for i := 0; i < idLength; i++ {
    b[i] = chars[rand.Intn(len(chars))]
  }
  return string(b)
}
// 32^8 = 1.1 trillion combinations
```

Protocol Impact:
- mid length changes from 5 to 8
- server should accept both during migration
- clients must be coordinated

---

## MEDIUM Severity Issues

### CVE-007: Message Size DoS
```dart
static const int MAX_MESSAGE_CHARS = 10000;
```

### CVE-008: No Timestamp Validation
```go
const MESSAGE_MAX_AGE = 30 * time.Minute
// Reject messages older than 30 minutes
```

### CVE-009: Metadata Leakage
- Add dummy queries every 60s (mask activity)
- Pad messages to 256/512/1024 byte boundaries
- Recommend VPN/proxy for sensitive use

### CVE-010: Content Fingerprinting
```dart
// Include timestamp or random padding to randomize ciphertext
final msg = plaintext + "[" + DateTime.now().toString() + "]";
```

---

## Reporting Vulnerabilities

IMPORTANT: Do not open public issues for security vulnerabilities.

Reporting Process:
1) Email: security@peyk-d.example.com (replace with actual email)
2) Include: vulnerability description, impact, proof-of-concept
3) Timeline: we aim to patch within 30 days
4) Embargo: please embargo disclosure 90 days

Responsible Disclosure:
- Acknowledge receipt within 24 hours
- Provide timeline for fix
- Credit in release notes (if desired)

---

## Security Best Practices for Operators

Pre-Deployment Checklist:
- Move all secrets to environment variables
- Implement rate limiting (CVE-003 mitigation)
- Add sender authentication (CVE-002 mitigation)
- Add goroutine semaphore (CVE-004 mitigation)
- Rotate passphrase every 90 days
- Monitor for suspicious activity
- Set up log aggregation
- Test backup/restore procedures
- Document incident response plan
- Security audit by third party

Runtime Monitoring:
Alert if:
- statRxPackets > 10,000/min (DDoS attack)
- statParseFail > 500/min (malformed packets)
- messageStore growth > 100MB (memory leak)
- GC frequency > 100/hour (churn indicator)
- single IP > 1,000 queries/min (reconnaissance)

Incident Response:
If domain compromised:
1) Immediately stop current server
2) Switch to backup domain (pre-configured)
3) Notify users via out-of-band channel
4) Rotate passphrase
5) Audit logs for breach window
6) Investigate root cause
7) Patch vulnerability
8) Redeploy on new infrastructure

---

## Changelog

| Date | Issue | Status | Notes |
|------|-------|--------|-------|
| 2026-01-15 | CVE-001 (Hardcoded creds) | UNFIXED | Move to env vars + secure storage |
| 2026-01-15 | CVE-002 (No sender auth) | UNFIXED | Shared-key HMAC is integrity only |
| 2026-01-15 | CVE-003 (DNS amplification) | UNFIXED | Token bucket + cleanup + response cap |
| 2026-01-15 | CVE-004 (Goroutine leak) | UNFIXED | Add semaphore channel |
| 2026-01-15 | CVE-005 (ACK2 replay) | UNFIXED | HMAC + timestamp in ACK2 |
| 2026-01-15 | CVE-006 (ID collision) | UNFIXED | Increase mid from 5 to 8 chars |
| 2026-01-17 | Document review and corrections | UPDATED | Clarified HMAC/nonce/rate-limit limitations |
| 2026-01-17 | Security analysis complete | DONE | Ready for implementation phase |

Last Updated: January 2026  
Next Review: April 2026  
Maintained By: Peyk-D Security Team
