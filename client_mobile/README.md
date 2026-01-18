# Peyk-D Mobile Client

Flutter-based chat UI for the Peyk-D protocol. It handles encryption, chunking, polling, and displays delivery status.

## Features

- **Chat per ID**: Each `ChatScreen(targetId: "abcde")` keeps isolated history.  
- **Direct modes**:  
  - `Other Countries (Slow)` → Direct UDP to server.  
  - `Other Countries (Fast)` → Direct DNS-over-TCP (use TCP for faster ACKs).  
  - `Advanced` → Custom IP/domain/polling with legacy fallback.  
- **Adaptive polling**: 20-40 seconds default, bursts to ~200ms when data arrives.  
- **Retry safety**: `_txInFlight` flag avoids parallel send/retry collisions.  
- **Settings persist**: SharedPreferences stores server IP, base domain, direct flags, stats.

## Setup

```bash
cd client_mobile
flutter pub get
flutter run -d <device>
```

Change `client_mobile/lib/core/protocol.dart` for base domain and default server IP. Use Settings to toggle `Direct TCP (Fast)` and `Send via AAAA`.

## Diagnostics

- Enable Debug mode to see frame assembly logs.  
- Stats line reports `TX` percent, `RX` percent, and status.  
- `Other Countries (Fast)` enables `DnsTransport(useTcp: true)` for all DNS queries and ACKs.

## Testing

Pair with `server/simulator.go`:

```bash
# terminal 1
cd server
go run simulator.go

# terminal 2
cd client_mobile
flutter run

# send messages between simulator and mobile client
```

