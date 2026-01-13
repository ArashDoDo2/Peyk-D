# Peyk-D | Secure DNS Tunneling Client

Peyk-D is an emergency communication tool designed to bypass network restrictions by tunneling encrypted data over DNS queries (RFC 1035).

## ✨ Features
- **AES-GCM 256-bit Encryption**: End-to-end security for every packet.
- **Dynamic Configuration**: Change Server IP, Base Domain, and Encryption Keys on the fly.
- **Visual Feedback**: Real-time transmission logs with smart status coloring.
- **Low Footprint**: Optimized for high-latency and restricted environments.
- **Modern UI**: Clean, Dark-themed interface with "Emergency Mode" branding.

## 🛠 Tech Stack
- **Flutter/Dart**: Cross-platform mobile client.
- **Cryptography**: AES-GCM implementation for secure handshakes.
- **UDP/DNS**: Raw socket programming for data exfiltration.

## 🚀 Quick Start
1. **Clone the repo:** `git clone https://github.com/arashdodo2/peyk-d/client-mobile`
2. **Install dependencies:** `flutter pub get`
3. **Build APK:** `flutter build apk --split-per-abi`
4. **Setup:** Open the app, go to Settings, and point to your Peyk-D Go Server.

## ⚠️ Disclaimer
This project is for educational and emergency communication purposes only. Always comply with local regulations regarding data transmission.