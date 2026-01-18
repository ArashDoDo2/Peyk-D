# Peyk-D: DNS Emergency Messenger

Peyk-D tunnels encrypted chat over DNS when TCP/HTTP are blocked. The Flutter client encodes text into encrypted Base32 frames and serves them through DNS A/AAAA queries. The Go server buffers chunks per recipient, exposes ACK2 delivery confirmations, and now accepts both UDP and TCP connections on port 53.

## Highlights

- **Encryption**: AES-256-GCM with SHA256-derived passphrase (nonce=12, MAC=16).  
- **Transport**: DNS labels (idx-tot-mid-sid-rid-payload); polling via AAAA (preferred) or A records.  
- **Delivery model**: Sender polls for ACK2, receiver polls for chunks, server stores [rid][message key][chunks].  
- **Direct modes**:  
  - *Other Countries (Slow)* → direct UDP socket to server (default).  
  - *Other Countries (Fast)* → direct TCP/53 (DNS-over-TCP).  
  - *Automatic* → rely on OS resolver (regular DNS).  
- **Monitoring**: Server prints a stats bar with UDP/TCP counters and logs per-packet activity.

## Architecture

| Component | Language | Role |
|-----------|----------|------|
| Server | Go | UDP+TCP 53 listener, chunk store, ACK2 queue, stats bar |
| Client | Flutter/Dart | Chat UI, settings, Rx assembly, transport, retries |
| Simulator | Go | CLI sender/receiver for testing without mobile UI |

## Getting started

### 1. Configure the domain

Edit `client_mobile/lib/core/protocol.dart`:
```dart
static const String baseDomain = "your-domain.tld";
static const String defaultServerIP = "1.2.3.4";
```

Edit `server/main.go` and `server/simulator.go` constants to the same domain/IP. For production, load these from environment variables (see `QUICK_FIX_GUIDE.md`).

### 2. Build and run the server

```bash
cd server
sudo go run main.go   # port 53 needs root
# or build: GOOS=linux GOARCH=amd64 go build -o peyk-d-server main.go
# and run with PEYK_DOMAIN/PASSPHRASE env vars for secrets
```

`main.go` now supports UDP and TCP 53, adaptive GC every 20s, and stats logging (set `ENABLE_STATS_BAR=true` or `ENABLE_STATS_LOG=true`).

### 3. Run the mobile client

```bash
cd client_mobile
flutter pub get
flutter run -d <device>
```

Settings panel lets you toggle:
* Node ID / target ID / server IP / base domain  
* Poll interval (min/max) and retry count  
* `Use direct server` + `Direct TCP (Fast)`  
* `Send via AAAA`, `Fallback to A`, `Debug mode`

### 4. Test with simulator

```bash
cd server
PEYK_DOMAIN=your-domain PEYK_PASSPHRASE=your-secret go run simulator.go
```

Use `DIRECT_SERVER_IP` to point at a running server and experiment with polls/ACK2.

## Settings & persistence

All client flags persist in SharedPreferences:

| Key | Description |
|-----|-------------|
| `server_ip`, `base_domain` | Direct server config |
| `use_direct_server` | Bypass OS resolver |
| `direct_tcp` | When true, transport uses DNS-over-TCP |
| `send_via_aaaa` | Try AAAA first for polls |
| `fallback_enabled` | Use A records when AAAA fails |
| `poll_min` / `poll_max` | Adaptive polling range |
| `retry_count` | Number of retries per chunk |

Selecting “Other Countries (Fast)” toggles both `use_direct_server` and `direct_tcp`.

## Security & maintenance

- **Secrets** should be injected via env vars (server) or `--dart-define` (client).  
- **Stats** now report UDP vs TCP rx/tx in the status bar and logs.  
- **Logs** include `[MSG-TX]`, `[MSG-RX]`, `[ACK2-TX/RX]`, and rate-limiting warnings.  
- **Critical docs**: see `SECURITY.md`, `QUICK_FIX_GUIDE.md`, `ANALYSIS_REPORT.md` for ongoing fixes.

## Contributing

1. Run Go unit tests (`go test ./...`) and Flutter analyzer (`flutter analyze`).  
2. Open PRs against `main` with clean `git status`.  
3. Document protocol tweaks in README + SECURITY.md.  

## Release notes

* `v1.2` (Jan 2026) – **Client & Server sync**  
  - Server now listens on UDP/TCP 53, exposes UDP/TCP stats (stats bar + log line), and supports direct TCP polls.  
  - Client adds “Other Countries (Fast)” mode (direct TCP) alongside “Slow” mode, exposes TCP count in stats line, and logs retries safely next to check marks.  
  - Documentation refreshed (README, guides, security policy, contributing) to reflect the new transport modes and monitoring options.  
* `v1.1` (Jan 2026) – Enhanced polling/ACK2 flow (poll jitter, delivery status, stats).  
* `v1.0` – Initial UDP-only emergency messenger with ACK2 delivery.

---
