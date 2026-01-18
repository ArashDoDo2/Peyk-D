# Peyk-D Quick Fix Guide

This page summarizes actionable steps for the highest-priority fixes before production deployment.

## Critical Issues (runbook)

| # | Symptom | Fix time | Notes |
|---|---------|----------|-------|
| 1 | Secrets hardcoded in source | 15 min | Move `PEYK_DOMAIN`/`PEYK_PASSPHRASE` to env vars and build-time defines. Update server, client, and simulator to read from env. |
| 2 | Missing sender authentication | 1-2 hrs | Add HMAC of plaintext with shared passphrase before encryption, then verify after decrypting. Reject messages whose signature fails. |
| 3 | DNS amplification potential | 1 hr | Rate-limit per source IP (token bucket), log when throttled, and cap AAAA/A response sizes. |
| 4 | Unlimited goroutines | 45 min | Add semaphore channel with cap ~(1000) to throttled `handlePacket`. |

## Monitoring tweaks

1. Enable `ENABLE_STATS_BAR=true` to draw the one-line dashboard with UDP/TCP counters + stats above log output.
2. Watch for `rateLimited` log messages once the bucket hit limit.
3. Toggle `ENABLE_STATS_LOG=true` for periodic 📊 logs.

## Deployment checklist

- [ ]  Build server with `GOOS=linux GOARCH=amd64 go build -o peyk-d-server main.go`.  
- [ ]  Set env vars before starting:  
   ```bash
   export PEYK_DOMAIN="example.com"
   export PEYK_PASSPHRASE="long-secret"
   ./peyk-d-server
   ```  
- [ ]  Use direct TCP mode for the client: flip `Other Countries (Fast)` and set `PEYK_DIRECT_SERVER_IP`.
- [ ]  Verify AES key lengths, message size limit (max 30 chunks), and polling settings via UI.
- [ ]  Confirm stats line shows `udp` vs `tcp` counters.

## Verification commands

- `grep -R --line-number PEYK_PASSPHRASE .` → should only appear in configuration or `.env`.
- `go test ./...` → run server tests after refactor.
- `flutter analyze` → lint Flutter client after transport changes.
- `sudo tcpdump -i any port 53` → ensure server receives both UDP and TCP frames when direct TCP mode is active.

