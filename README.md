# Peyk-D
A lightweight, high-latency, and resilient communication tool designed for emergency situations where standard internet protocols (HTTP/TCP) are restricted, but DNS resolution remains functional.

## 📖 Overview
In crisis scenarios, DNS often remains the last standing bridge between a restricted network and the global internet. BeaconDNS utilizes the DNS protocol to transmit short, end-to-end encrypted text messages between a user inside a restricted zone and a recipient outside.

### ⚠️ Project Scope
- **Target:** Emergency short messaging (SMS-style).
- **Not for:** Browsing, VPN, file transfer, or high-speed chat.
- **Focus:** Simplicity, Low-detectability, and High-compatibility.

---

## 🏗️ System Architecture



1. **Iran Client:** A simple UI that encodes and encrypts messages into DNS queries (subdomains).
2. **DNS Gateway (Server):** An authoritative DNS server that intercepts queries, extracts data, and stores messages in a queue.
3. **Outside UI:** A web or CLI interface for the external user to read and reply to messages.

---

## 🔒 Security Features
- **End-to-End Encryption (E2EE):** Messages are encrypted/decrypted only on the clients using AEAD (e.g., ChaCha20-Poly1305).
- **Anti-Replay:** Implements sequence counters and timestamp windows.
- **Privacy:** The Gateway only sees encrypted blobs; no raw text is stored.
- **Base32 Encoding:** Ensures DNS compatibility and avoids case-sensitivity issues.

---

## 🚀 Getting Started

### Prerequisites
- A domain name (e.g., `example.com`).
- A VPS with a public IP.
- Port 53 (UDP) must be open.

### Server Setup (Quick Start)
1. Disable local DNS resolvers:
   ```bash
   sudo systemctl stop systemd-resolved
   sudo systemctl disable systemd-resolved
