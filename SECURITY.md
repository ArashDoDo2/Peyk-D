# Peyk-D Security Policy

## Overview

Peyk-D protects encrypted messaging over DNS. All contributions must preserve confidentiality, reject hardcoded secrets, and follow the disclosure process below.

## Critical Vulnerabilities (Must Fix Before Production)

1. **CVE-001 – Hardcoded domain/passphrase**: Secrets must come from `PEYK_DOMAIN`/`PEYK_PASSPHRASE` environment variables or `--dart-define`.  
2. **CVE-002 – Missing sender integrity**: Incoming plaintext must carry an HMAC (or equivalent) to detect spoofing before showing to users.  
3. **CVE-003 – DNS amplification risk**: Implement rate limiting per IP (token bucket) and cap response size to prevent abuse.  
4. **CVE-004 – Unbounded goroutines**: Add semaphore for `handlePacket` to limit concurrent handlers and avoid memory DoS.

## Additional Risks

- **Metadata leakage**: Query timing/frequency reveals relationships; consider noise padding or dummy queries.  
- **Replay attacks**: Add timestamp/nonces inside ACK2 to reject stale confirmations.  
- **Collision risk**: Expand message ID from 5 to 8 characters before large deployments.

## Monitoring

Set `ENABLE_STATS_BAR=true` to view the UDP/TCP stats line every 2s:

```
STATS udp rx=12 tx=12 | tcp rx=3 tx=3 | rx=15 tx=15 polls=4 ...
```

Enable `ENABLE_STATS_LOG=true` for periodic logs and watch for `rateLimited`.

## Reporting

Send vulnerabilities to `security@peyk-d.example.com` with classification, impact, and reproduction steps. Embargo disclosure for 90 days unless authorized otherwise.

## Responsible Disclosure Process

1. Acknowledge within 24h.  
2. Provide fix timeline.  
3. Credit contributor if desired.  
4. Update `SECURITY.md` with status/resolution.

## Hardening Checklist

- [ ] Move secrets to environment variables  
- [ ] Enable rate limiting (token bucket + cleanup)  
- [ ] Add HMAC integrity or sender keys  
- [ ] Keep goroutine count bounded  
- [ ] Rotate domains/passphrases periodically  
- [ ] Monitor `statRxPackets`, `statTxPackets`, `statRateLimited`, `statParseFail`  
- [ ] Document incident response plan (backup domain, passphrase rotation)
