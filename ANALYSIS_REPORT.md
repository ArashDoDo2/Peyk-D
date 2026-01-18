# Peyk-D Code Analysis & Security Audit

**Date**: January 2026  
**Status**: Updated with TCP direct mode + stats  

## Summary

- **Architecture**: Go server (UDP/TCP) + Flutter client + Go simulator. Clear separation of transport, encryption, UI, and diagnostics.  
- **Security posture**: AES-256-GCM + ACK2 confirmation, but still needs env-based secrets, sender authentication, rate limiting, and goroutine limits.  
- **Current strengths**: Adaptive polling, deduplication, modular RFC-compliant DNS handling, stats bar with UDP/TCP counters.

## Key Recommendations

1. **Move secrets out of source** (env vars + flutter define).  
2. **Add sender integrity** (HMAC before encryption, verify after decrypt).  
3. **Rate limit per source IP** (token bucket).  
4. **Cap goroutines** (semaphore to cap `handlePacket` concurrency).  
5. **Add timestamp validation & message sizing** (future improvement).  

## Monitoring notes

- Stats bar prints `STATS udp rx=... tx=... | tcp rx=... tx=...` + overall counters to stderr every 2s.  
- `ENABLE_STATS_LOG=true` emits detailed logs with `rxChunks`, `txA/AAAA/APay`, parse failures, and storage metrics.  
- Logs include `[MSG-TX]`, `[MSG-RX]`, `[ACK2-TX]`, `[ACK2-RX]`, [`rateLimited`] after TCP addition.

## Ready for next steps

1. Complete fixes above, verify via `go test ./...` and `flutter analyze`.  
2. Document deployment process (env, direct TCP option).  
3. Maintain quarterly security reviews.
