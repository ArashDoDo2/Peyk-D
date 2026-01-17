# Peyk-D: Quick-Fix Guide for Critical Issues

**Status**: 🚨 4 Critical Issues Found  
**Estimated Fix Time**: 6-8 hours total  
**Difficulty**: Low-Medium

---

## 🔴 Issue #1: Hardcoded Credentials (CRITICAL)

**Problem**: Passphrase and domain visible in source code

**Current Code** (BAD):
```go
// server/main.go
const BASE_DOMAIN = "example.com"
const PASSPHRASE = "strong-secret-here"

// client_mobile/lib/core/protocol.dart
static const String passphrase = "strong-secret-here";
```

**Fix** (5 minutes):

1. **Create `.env` file** (don't commit!):
   ```bash
   # .env (NOT in git, add to .gitignore)
   PEYK_DOMAIN=example.com
   PEYK_PASSPHRASE=$(openssl rand -base64 32)
   ```

2. **Add to `.gitignore`**:
   ```bash
   echo ".env" >> .gitignore
   ```

3. **Update `server/main.go`**:
   ```go
   package main

   import "os"

   var (
     BASE_DOMAIN string
     PASSPHRASE  string
   )

   func init() {
     BASE_DOMAIN = os.Getenv("PEYK_DOMAIN")
     PASSPHRASE = os.Getenv("PEYK_PASSPHRASE")
     
     if BASE_DOMAIN == "" || PASSPHRASE == "" {
       log.Fatal("Set PEYK_DOMAIN and PEYK_PASSPHRASE env vars")
     }
   }
   ```

4. **Update `server/simulator.go`**:
   ```go
   var (
     BASE_DOMAIN = os.Getenv("PEYK_DOMAIN")
     PASSPHRASE  = os.Getenv("PEYK_PASSPHRASE")
   )
   ```

5. **Update `client_mobile/lib/core/protocol.dart`**:
   ```dart
   // Remove hardcoded, use secure storage instead
   import 'package:flutter_secure_storage/flutter_secure_storage.dart';

   class PeykProtocol {
     static const String baseDomain = "example.com";  // OK (domain OK)
     
     static Future<String> getPassphrase() async {
       const storage = FlutterSecureStorage();
       return await storage.read(key: 'peyk_passphrase') 
         ?? 'fallback-dev-only';
     }
   }
   ```

6. **Run**:
   ```bash
   export PEYK_DOMAIN="example.com"
   export PEYK_PASSPHRASE="super-strong-password-32-chars"
   go run main.go
   ```

**Verification**:
```bash
# Should not show secrets
grep -r "my-fixed-passphrase" . --include="*.go" --include="*.dart"
# Should be empty
```

---

## 🔴 Issue #2: No Sender Authentication (CRITICAL)

**Problem**: Any client can impersonate any sender

**Current Code** (BAD):
```
Attacker sends: 1-1-mid-attacker-bob-"malicious"
Bob sees it as from "attacker" with no proof
→ Social engineering attack
```

**Fix** (3 hours):

**Option A: HMAC-SHA256** (Recommended, quick)

1. **Create `client_mobile/lib/core/crypto_hmac.dart`**:
   ```dart
   import 'dart:convert';
   import 'dart:typed_data';
   import 'package:crypto/crypto.dart';
   import './protocol.dart';

   class PeykCryptoHmac {
     static String signMessage(String plaintext) {
       final keyBytes = utf8.encode(PeykProtocol.passphrase);
       final bytes = utf8.encode(plaintext);
       final hmac = Hmac(sha256, keyBytes);
       final digest = hmac.convert(bytes);
       final sig = digest.toString().substring(0, 16);  // First 16 chars
       return plaintext + ";" + sig;
     }

     static bool verifyMessage(String signed) {
       final parts = signed.split(';');
       if (parts.length != 2) return false;
       
       final plaintext = parts[0];
       final givenSig = parts[1];
       
       final expected = signMessage(plaintext);
       final expectedSig = expected.split(';')[1];
       
       return givenSig == expectedSig;
     }
   }
   ```

2. **Update `chat_screen.dart` TX**:
   ```dart
   void _sendMessage() async {
     final text = _controller.text.trim();
     if (text.isEmpty) return;
     
     // Sign message before encryption
     final signed = PeykCryptoHmac.signMessage(text);
     
     final encrypted = await PeykCrypto.encrypt(signed);  // Sign → Encrypt
     // ... rest of send logic
   }
   ```

3. **Update `chat_screen.dart` RX**:
   ```dart
   Future<void> assembleAndDecrypt(key, total, senderID, mid) async {
     // ... assembly code ...
     
     final decrypted = await PeykCrypto.decrypt(encrypted);
     
     // Verify signature
     if (!PeykCryptoHmac.verifyMessage(decrypted)) {
       print("❌ SIGNATURE INVALID - Possible spoofing!");
       return;  // Reject
     }
     
     final plaintext = decrypted.split(';')[0];
     
     // Display verified message
     _addMessage(plaintext, senderID, mid);
   }
   ```

**Testing**:
```dart
// Test HMAC
final signed = PeykCryptoHmac.signMessage("hello");
assert(PeykCryptoHmac.verifyMessage(signed) == true);
assert(PeykCryptoHmac.verifyMessage("corrupted") == false);
```

---

## 🔴 Issue #3: DNS Amplification Attack (CRITICAL)

**Problem**: Server can be used as DDoS amplifier

**Current Code** (BAD):
```
Attacker spoofs: query from victim (really from attacker)
Server responds: Large AAAA response
Victim: Flooded with responses
```

**Fix** (1 hour):

**Add Rate Limiting to `server/main.go`**:

```go
import (
  "sync"
  "time"
)

const (
  RATE_LIMIT_PER_IP = 100  // queries per second
)

var (
  rateLimiters = make(map[string]time.Time)
  rateLimitMu  sync.RWMutex
)

func checkRateLimit(ip string) bool {
  rateLimitMu.Lock()
  defer rateLimitMu.Unlock()
  
  now := time.Now()
  lastQuery := rateLimiters[ip]
  minGap := time.Second / time.Duration(RATE_LIMIT_PER_IP)
  
  if now.Sub(lastQuery) >= minGap {
    rateLimiters[ip] = now
    return true  // Allow
  }
  
  return false  // Blocked
}

func handlePacket(conn *net.UDPConn, addr *net.UDPAddr, data []byte) {
  // ADD THIS CHECK:
  if !checkRateLimit(addr.IP.String()) {
    atomic.AddUint64(&statRateLimited, 1)
    return  // Drop packet silently
  }
  
  // ... rest of packet handling
}
```

**Add stat counter** (in the constants section):
```go
var statRateLimited uint64
```

**Update stats logger** to include:
```go
rateLimited := atomic.LoadUint64(&statRateLimited)
log.Printf("... rateLimited=%d ...", rateLimited)
```

**Testing**:
```bash
# Simulate attack
for i in {1..200}; do
  dig @127.0.0.1 v1.sync.test.x.example.com &
done

# Check logs for "rateLimited" counter increasing
```

---

## 🔴 Issue #4: Unbounded Goroutines (CRITICAL)

**Problem**: Each packet spawns goroutine → memory exhaustion on DoS

**Current Code** (BAD):
```go
for {
  n, remoteAddr, err := conn.ReadFromUDP(buf)
  if err != nil { continue }
  
  pkt := make([]byte, n)
  copy(pkt, buf[:n])
  go handlePacket(conn, remoteAddr, pkt)  // No limit!
}
```

**Fix** (1 hour):

**Add semaphore to `server/main.go`**:

```go
const MAX_CONCURRENT_HANDLERS = 1000

var handlerSem = make(chan struct{}, MAX_CONCURRENT_HANDLERS)

func main() {
  log.SetFlags(log.LstdFlags | log.Lmicroseconds)
  rand.Seed(time.Now().UnixNano())

  addr := net.UDPAddr{Port: LISTEN_PORT, IP: net.ParseIP(LISTEN_IP)}
  conn, err := net.ListenUDP("udp", &addr)
  if err != nil {
    log.Fatal(err)
  }
  defer conn.Close()

  go garbageCollector()
  go statsLogger()

  log.Printf("PEYK-D server listening on %s:%d (udp)", LISTEN_IP, LISTEN_PORT)

  buf := make([]byte, 512)
  for {
    n, remoteAddr, err := conn.ReadFromUDP(buf)
    if err != nil {
      continue
    }
    atomic.AddUint64(&statRxPackets, 1)

    pkt := make([]byte, n)
    copy(pkt, buf[:n])
    
    // ADD THIS: Acquire semaphore
    handlerSem <- struct{}{}
    
    go func() {
      defer func() { <-handlerSem }()  // Release semaphore
      handlePacket(conn, remoteAddr, pkt)
    }()
  }
}
```

**Testing**:
```bash
# Simulate many requests
for i in {1..2000}; do
  dig @127.0.0.1 v1.sync.test.x.example.com &
done

# Monitor goroutines
curl http://localhost:6060/debug/pprof/goroutine

# Should stay around 1,000-1,100 (not 10,000+)
```

---

## Summary of Changes

| Issue | File | Lines | Time |
|-------|------|-------|------|
| #1: Credentials | main.go, simulator.go, protocol.dart | 15 | 30 min |
| #2: Auth | crypto_hmac.dart, chat_screen.dart | 40 | 2 hours |
| #3: Rate Limit | main.go | 20 | 1 hour |
| #4: Semaphore | main.go | 8 | 30 min |
| **TOTAL** | **4 files** | **~80 lines** | **4-5 hours** |

---

## Verification Checklist

After applying fixes:

- [ ] `grep -r "my-fixed-passphrase" .` → empty
- [ ] Environment variables required in startup
- [ ] Rate limiting rejects >100 queries/sec per IP
- [ ] Semaphore prevents >1,000 concurrent handlers
- [ ] HMAC signatures verified on received messages
- [ ] Server logs show rate limit stats
- [ ] No hardcoded secrets in compiled binaries

---

## Deploy Verification

```bash
# 1. Build with new code
go build -o peyk-d-server main.go

# 2. Start with env vars
export PEYK_DOMAIN="example.com"
export PEYK_PASSPHRASE="strong-32-char-password"
./peyk-d-server

# 3. Check logs
# Should show: "PEYK-D server listening on 0.0.0.0:53 (udp)"

# 4. Test with simulator
export PEYK_DOMAIN="example.com"
export PEYK_PASSPHRASE="strong-32-char-password"
go run simulator.go

# 5. Test client (Flutter)
flutter run

# 6. Send test message → Should work without showing hardcoded secrets
```

---

**Next Steps**: After fixing these 4 critical issues, refer to `SECURITY.md` for medium/low severity improvements.
