# Peyk-D: DNS-Based Emergency Messaging

[![License](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)
[![Go Version](https://img.shields.io/badge/go-1.25.5-blue)](https://golang.org)
[![Flutter](https://img.shields.io/badge/flutter-3.10.7+-blue)](https://flutter.dev)

**Peyk-D** is an end-to-end encrypted messaging system designed for severely restricted networks where TCP/HTTP are blocked but UDP/DNS remains functional. It encodes encrypted messages into DNS queries and responses to provide emergency communication when standard protocols fail.

## 🎯 Purpose

In crisis scenarios (internet shutdowns, firewall restrictions, censorship), DNS is often the **last communication channel** that remains available. Peyk-D leverages this by:

- **Encoding encrypted messages into DNS queries** (as DNS labels)
- **Transmitting via DNS A/AAAA records** instead of standard protocols
- **Providing end-to-end encryption** so even DNS servers cannot read message content
- **Supporting one-to-one asynchronous messaging** with delivery confirmation
- **Working on any network that allows DNS resolution**

## ⚡ Key Features

- ✅ **End-to-End AES-256-GCM Encryption** – SHA256 passphrase-based key derivation
- ✅ **DNS-Only Transport** – No TCP, no HTTP, no alternative protocols needed
- ✅ **Delivery Confirmation** – ACK2 mechanism to verify message receipt
- ✅ **Multi-Chat Support** – Isolated per-conversation history and contact management
- ✅ **Adaptive Polling** – Backoff algorithm to minimize bandwidth and battery drain
- ✅ **Frame Reassembly** – Automatic chunking and reordering of fragmented messages
- ✅ **Backward Compatibility** – Protocol supports both legacy and new frame formats
- ✅ **iOS & Android Ready** – Flutter-based native mobile app
- ✅ **Reference Implementation** – Go CLI simulator for testing without mobile framework

---

## 📦 Architecture

### Three-Tier System

| Component | Language | Purpose | Size |
|-----------|----------|---------|------|
| **Server** | Go | Listens on UDP/53, buffers chunks, serves via polling | 810 lines |
| **Client** | Flutter/Dart | Mobile UI, encryption, polling, chat history | ~2500 lines |
| **Simulator** | Go | CLI test client for crypto/DNS verification | 731 lines |

### Protocol Stack

```
Plaintext Message
        ↓
    AES-256-GCM Encryption (12-byte nonce + payload + 16-byte MAC)
        ↓
    Base32 Encoding (to fit DNS labels, strip padding)
        ↓
    Split into 30-char chunks
        ↓
    Wrap as DNS Frame: idx-tot-[mid-]sid-rid-payload
        ↓
    Send via UDP/53 as A or AAAA query
        ↓
    Server buffers chunks → Client polls → Reassembles → Decrypts
```

### Message Flow

**Sending (TX):**
1. User types plaintext → Client encrypts with passphrase
2. Encrypted bytes encoded to Base32 → split into 30-char chunks
3. Each chunk wrapped as DNS query: `idx-tot-mid-sid-rid-payload.domain.tld`
4. Sent via raw UDP/53 to server (or via OS DNS resolver)
5. Retried `_retryCount+1` times (default: 2 total sends per chunk)

**Receiving (RX):**
1. Client polls server: `v1.sync.<myID>.<nonce>.<domain>`
2. Server responds with:
   - ACK2 confirmations (delivery status)
   - Buffered message chunks
   - "NOP" if no messages
3. Client reassembles chunks → normalizes Base32 → decrypts → displays in chat

**Delivery Confirmation:**
1. After full message received, client sends: `ack2-<sid>-<tot>[-<mid>].<nonce>.<domain>`
2. Server queues ACK2 for sender (24h TTL)
3. Sender's next poll receives ACK2 → marks message as "delivered"

---

## 🚀 Quick Start

### Prerequisites

- **Server**: Go 1.25.5+
- **Client**: Flutter 3.10.7+, Android/iOS device or emulator
- **Network**: DNS access to your authoritative domain
- **Domain**: DNS domain where you're the authoritative nameserver

### 1. Configure Base Domain

Edit [client_mobile/lib/core/protocol.dart](client_mobile/lib/core/protocol.dart):
```dart
static const String baseDomain = "your-domain.tld";  // Change this
static const String passphrase = "your-secret-key";  // Change this
static const String defaultServerIP = "1.2.3.4";     // Server IP
```

Edit [server/main.go](server/main.go):
```go
const BASE_DOMAIN = "your-domain.tld"  // Must match client
```

Edit [server/simulator.go](server/simulator.go):
```go
const BASE_DOMAIN = "your-domain.tld"  // Must match client
```

### 2. Run Server

```bash
cd server
sudo go run main.go  # Requires admin for port 53
# Or use non-standard port + firewall redirect
```

**Monitor logs:**
```bash
# Enable stats logging in main.go
ENABLE_STATS_LOG=true

# Watch for tags:
# [MSG-RX] - message received
# [MSG-TX] - message served to client
# [ACK2-RX] - delivery confirmation received
# [ACK2-TX] - delivery confirmation sent
```

### 3. Test with Simulator

```bash
cd server
go run simulator.go

# Set DIRECT_SERVER_IP="127.0.0.1" for local testing
# Type message and press Enter
# Watch adaptive polling (350ms-5s backoff)
```

### 4. Run Mobile Client

```bash
cd client_mobile
flutter pub get
flutter run -d <device-id>

# On first launch:
# - Auto-generates 5-char ID (my_id)
# - Requires target_id input (recipient's 5-char ID)
# - Polls every 20-40s (configurable)
```

---

## 🔧 Configuration

### Client Settings (SharedPreferences)

| Setting | Type | Default | Purpose |
|---------|------|---------|---------|
| `my_id` | String | Auto-gen | Your unique 5-char Base32 ID |
| `target_id` | String | (empty) | Recipient's 5-char ID |
| `server_ip` | String | Configurable | Relay server IP |
| `base_domain` | String | Configurable | DNS domain (authoritative) |
| `poll_min` | Int | 20 | Min poll interval (seconds) |
| `poll_max` | Int | 40 | Max poll interval (seconds) |
| `retry_count` | Int | 1 | Retries per chunk (1 = 2 sends) |
| `polling_enabled` | Bool | true | Enable auto-polling |
| `debug_mode` | Bool | false | Print frame assembly logs |
| `fallback_enabled` | Bool | false | Try A if AAAA fails |
| `use_direct_server` | Bool | false | Direct UDP vs OS resolver |
| `send_via_aaaa` | Bool | false | Send via AAAA (experimental) |
| `contacts_names` | JSON | {} | ID → display name mapping |
| `contacts_unread` | JSON | {} | ID → unread count mapping |

### Server Constants (main.go)

```go
const (
    MESSAGE_TTL       = 24 * time.Hour    // Chunk retention
    ACK2_TTL          = 24 * time.Hour    // ACK2 confirmation retention
    GC_EVERY          = 20 * time.Second  // Garbage collection interval
    PAYLOAD_PREVIEW   = 24                // Chars to log
    ENABLE_STATS_LOG  = false             // Real-time packet stats
    ENABLE_RX_CHUNK_LOG = false           // Log each chunk received
    ENABLE_ACK2_LOG   = false             // Log delivery confirmations
    ENABLE_GC_LOG     = true              // Log garbage collection
)
```

---

## 💡 Usage Patterns

### Single Chat Session

```dart
ChatScreen(
  targetId: "alice5",  // Recipient's ID
  displayName: "Alice",
)
```

### Multi-Chat (Different Recipients)

```dart
// Each instance is independent
ChatScreen(targetId: "alice5", displayName: "Alice")
ChatScreen(targetId: "bob7a", displayName: "Bob")
ChatScreen(targetId: "carol2", displayName: "Carol")

// Histories isolated: chat_history_myid_targetid
// Unread counts tracked per contact
```

### Encryption/Decryption Example

```dart
// Encrypt plaintext with passphrase
final plaintext = "Emergency: Need help";
final encrypted = await PeykCrypto.encrypt(plaintext);
// → Uint8List: [nonce(12) + ciphertext + mac(16)]

// Base32 encode for DNS transport
final b32 = base32.encode(encrypted).toLowerCase().replaceAll('=', '');
// → "xyz7...abc2" (DNS-safe)

// Decrypt on receive
final decrypted = await PeykCrypto.decrypt(encryptedBytes);
// → "Emergency: Need help"
```

---

## 📊 Protocol Details

### DNS Frame Format

**Legacy (5 parts):**
```
idx-tot-sid-rid-payload
1-3-abc7d-xyz2a-hello
↑   ↑   ↑     ↑     ↑
│   │   │     │     └─ Base32 payload (30 chars max)
│   │   │     └─ Receiver ID (5 chars)
│   │   └─ Sender ID (5 chars)
│   └─ Total chunks
└─ Chunk index (1-based)
```

**New (6 parts, with message ID):**
```
idx-tot-mid-sid-rid-payload
1-3-msg12-abc7d-xyz2a-hello
↑   ↑   ↑     ↑     ↑     ↑
│   │   │     │     │     └─ Payload
│   │   │     │     └─ Receiver ID
│   │   │     └─ Sender ID
│   │   └─ Message ID (for multi-chat relay)
│   └─ Total chunks
└─ Chunk index
```

### DNS Query Types

| Type | Purpose | Direction | Response |
|------|---------|-----------|----------|
| **A (1)** | Send chunks, ACKs | Client→Server | Fixed IP 3.4.0.0 |
| **AAAA (28)** | Poll for messages | Client→Server | AAAA RRs with payload |
| **A fallback** | Poll if AAAA fails | Client→Server | A RRs with payload (less efficient) |

### Payload Packing (AAAA Response)

```
45-byte payload → 3 AAAA RRs:

RR1: [0x01] + 15 bytes (payload[0:15])
     Index 1, bytes 0-14 of message

RR2: [0x02] + 15 bytes (payload[15:30])
     Index 2, bytes 15-29 of message

RR3: [0x03] + 15 bytes (payload[30:45])
     Index 3, bytes 30-44 of message

Client reassembles ordered by index byte
```

---

## 🔐 Security

### Encryption

- **Algorithm**: AES-256-GCM (RFC 5116)
- **Key**: SHA256(passphrase) → 32 bytes
- **Nonce**: 12 random bytes (sent in every message)
- **MAC**: 16-byte authentication tag (detects tampering)
- **Format**: `nonce(12) || ciphertext || mac(16)`

### Threat Model

**Strong Encryption Provides:**
- ✅ Content confidentiality (even DNS servers can't read)
- ✅ Tamper detection (MAC rejects altered messages)
- ✅ Replay protection (nonce + message IDs prevent replays)

**DNS Still Leaks:**
- ⚠️ Metadata (sender/receiver IDs, message size, timing)
- ⚠️ Frequency of communication (DPI can detect patterns)
- ⚠️ Domain name (authoritative domain is visible)

**Mitigations:**
- Use VPN/proxy if metadata protection needed
- Rotate domains periodically
- Add dummy queries to obscure patterns

### Passphrase

- **Shared secret** between sender and receiver (pre-distributed)
- **No key exchange** on network (would be visible to DNS servers)
- **MUST be strong** and unique per conversation pair
- **Change it** if compromised

---

## 📱 Mobile Client Features

### Chat Interface

- **Per-conversation threading** – Each recipient gets isolated chat
- **Message bubbles** – Color-coded (sent: teal, received: gray)
- **Delivery status** – ✓ sent, ✓✓ delivered, ⏳ pending
- **Contact names** – Optional display names instead of IDs
- **Unread counts** – Track messages from each contact
- **Copy & paste** – Long-press to copy, paste button in input
- **Clear history** – Delete all messages for one contact

### Settings Panel

- **Node ID** – Auto-generated, shown with glow animation
- **Connection** – Target ID, server IP, base domain, direct mode toggle
- **Polling** – Min/max intervals, retry count, fallback mode
- **Advanced** – Send via AAAA (experimental), debug logs
- **Actions** – Clear chat, apply settings

### Debug Mode

Enable "Debug Mode" in settings to see:
- Frame assembly logs
- Base32 encoding/decoding steps
- Payload validation
- Decryption errors (with raw bytes for diagnosis)

---

## 🧪 Testing

### Unit Testing (Crypto)

```dart
// Verify encryption/decryption
final plaintext = "test message";
final encrypted = await PeykCrypto.encrypt(plaintext);
final decrypted = await PeykCrypto.decrypt(encrypted);
assert(decrypted == plaintext);
```

### End-to-End Testing

```bash
# Terminal 1: Start server
cd server
sudo go run main.go

# Terminal 2: Run simulator as sender
cd server
DIRECT_SERVER_IP="127.0.0.1" go run simulator.go
# Type: "hello from simulator"

# Terminal 3: Run simulator as receiver
cd server
DIRECT_SERVER_IP="127.0.0.1" go run simulator.go
# MY_ID="recv1" TARGET_ID="simul"
# Wait for message to arrive

# Both should show latency metrics and ACK2 confirmations
```

### Mobile Testing

1. Configure simulator and server on same network
2. Set `use_direct_server=true` and point to server IP
3. Set `target_id` to simulator's MY_ID
4. Send message and verify delivery
5. Simulator sends response, check delivery confirmation

---

## ⚠️ Limitations & Constraints

| Constraint | Value | Reason |
|-----------|-------|--------|
| **Message size** | ~1500-2000 chars | Base32 encoding + encryption overhead |
| **Chunk size** | 30 chars max | DNS label limit (63) minus header |
| **Throughput** | ~5-10 msgs/min | Polling interval + round-trip time |
| **Latency** | 20-120 seconds | Polling jitter + server GC |
| **Retention** | 24 hours | TTL on server (GC every 20s) |
| **Sender IDs** | 5 chars (Base32) | DNS label restrictions |
| **Domains** | 1 per deployment | Must be authoritative |
| **Recipients** | 1 per ChatScreen | Create new instance per contact |

**Not Suitable For:**
- Real-time chat (use messaging apps)
- File transfer (text-only)
- Anonymity (metadata visible)
- Large-scale distribution (one-to-one only)

---

## 🔄 Development Workflow

### Making Changes

1. **Server changes** → Edit `server/main.go` or `server/simulator.go`
   ```bash
   cd server
   go run main.go
   ```

2. **Client changes** → Edit `client_mobile/lib/...`
   ```bash
   cd client_mobile
   flutter run -d <device>
   ```

3. **Crypto changes** → Test with simulator first
   ```bash
   cd server
   go run simulator.go
   ```

4. **Protocol changes** → Update both server AND client, test with simulator

### Adding Features

- **New settings**: Add to SharedPreferences keys in `chat_screen.dart`
- **New frame fields**: Update parser in `_handleIncomingChunk()` (support legacy)
- **New query types**: Add routing in `handlePacket()` (server/main.go)
- **Encryption changes**: Test with `simulator.go` before mobile deployment

---

## 📝 File Structure

```
peyk-d/
├── README.md                          # This file
├── LICENSE                            # AGPL-3.0
├── .github/
│   └── copilot-instructions.md        # AI agent guidelines
├── server/
│   ├── main.go                        # DNS server (UDP/53)
│   ├── simulator.go                   # CLI test client
│   └── go.mod                         # Go dependencies
└── client_mobile/
    ├── pubspec.yaml                   # Flutter dependencies
    ├── lib/
    │   ├── main.dart                  # App entry
    │   ├── app.dart                   # Theme & navigation
    │   ├── ui/
    │   │   └── chat_screen.dart       # Main chat UI (~900 lines)
    │   ├── core/
    │   │   ├── protocol.dart          # Constants & validation
    │   │   ├── crypto.dart            # AES-256-GCM
    │   │   ├── dns_codec.dart         # DNS packet build/parse
    │   │   ├── transport.dart         # UDP socket + polling
    │   │   └── rx_assembly.dart       # Frame dedup & assembly
    │   └── utils/
    │       └── id.dart                # ID generation
    └── android/, ios/, etc/           # Platform code
```

---

## 🤝 Contributing

This project is designed for resilience and simplicity. When contributing:

- Keep DNS packet handling RFC-compliant
- Maintain backward compatibility with frame formats
- Test crypto changes with `simulator.go`
- Document new constants and flags
- Keep metadata leakage to minimum

---

## 📜 License

**AGPL-3.0** – See [LICENSE](LICENSE) file

Recommended for:
- Open-source deployments
- Community-run infrastructure
- Humanitarian use cases

**Alternative:** Contact maintainers for Apache-2.0 licensing if needed.

---

## ⚡ Troubleshooting

### Server won't start
```
Error: listen udp :53: permission denied
```
**Solution**: Run with `sudo` or redirect port 53:
```bash
sudo iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-port 5353
go run main.go  # Listen on 5353
```

### Client can't reach server
- Check `use_direct_server=true` in settings
- Verify server IP in `server_ip` field
- Test connectivity: `nslookup example.com <server_ip>`
- Check firewall allows UDP/53

### Messages not decrypting
```
Decryption error: Invalid Passphrase or Corrupted Data
```
**Verify:**
- Passphrase matches exactly (case-sensitive)
- Both client and server use same passphrase
- Network didn't corrupt chunks (enable debug mode)

### Polling too slow
- Decrease `poll_min` (min 5s recommended)
- Increase `poll_max` (max 60s safe)
- Enable `fallback_enabled` if AAAA fails

### High latency
- Expected: 20-120 seconds per message
- Caused by: polling interval, network jitter, server GC
- Not a bug: DNS is inherently high-latency

---

## 📚 Related Documentation

- **AI Guidelines**: [.github/copilot-instructions.md](.github/copilot-instructions.md)
- **Protocol Spec**: See `main.go` comments for DNS handling
- **Crypto Spec**: See `crypto.dart` for AES-GCM implementation
- **Frame Format**: See `rx_assembly.dart` for assembly logic

---

## 🎓 Educational Value

Peyk-D demonstrates:
- **DNS protocol** – Raw packet parsing and building (RFC 1035)
- **Cryptography** – AES-GCM with AEAD (RFC 5116)
- **Network resilience** – Store-and-forward, polling, backoff
- **Mobile development** – Flutter state management, SharedPreferences
- **Go concurrency** – Goroutines, channels, mutexes

Perfect for learning or teaching network fundamentals.

---

## 🙏 Acknowledgments

Built with:
- **Go** – https://golang.org
- **Flutter/Dart** – https://flutter.dev
- **cryptography** – https://pub.dev/packages/cryptography
- **base32** – https://pub.dev/packages/base32

Inspired by constraints and principles of resilient communication systems.

---

**Stay connected, even when the internet isn't.** 🌍
