# Security Policy & Threat Model

### Threat Model:
* **Adversary:** Active network observer with DPI capabilities.
* **Defense:** E2EE (ChaCha20-Poly1305) + Timing Obfuscation (Jitter).
* **Limitations:** Peyk-D does not provide anonymity; it provides **reachability**. The ISP can see that you are communicating with our DNS server, but not what you are saying.

### Reporting Vulnerabilities:
Please do not open public issues for security vulnerabilities. Contact the maintainers privately.
