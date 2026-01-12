import 'dart:io';
import 'dart:convert';
import 'dart:typed_data'; // حتماً این خط را اضافه کنید
import 'package:flutter/material.dart';
import 'package:base32/base32.dart';
import 'package:encrypt/encrypt.dart' as enc;

void main() {
  runApp(const PeykDApp());
}

class PeykDApp extends StatelessWidget {
  const PeykDApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false, // حذف نوار تست
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const MessageScreen(),
    );
  }
}

class MessageScreen extends StatefulWidget {
  const MessageScreen({super.key});

  @override
  State<MessageScreen> createState() => _MessageScreenState();
}

class _MessageScreenState extends State<MessageScreen> {
  final TextEditingController _controller = TextEditingController();
  String _status = "Ready to send";

  // تابع ارسال پکت واقعی UDP به سمت کامپیوتر
void sendDnsMessage(String message) async {
  if (message.isEmpty) return;

  try {
    // ۱. تنظیم کلید و IV (باید دقیقا با سرور یکی باشد)
    final key = enc.Key.fromUtf8('my32characterslongsecretkey12345'); // ۳۲ کاراکتر
    final iv = enc.IV.fromUtf8('1212312312312312'); // ۱۶ کاراکتر
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));

    // ۲. رمزنگاری متن اصلی
    final encrypted = encrypter.encrypt(message, iv: iv);
    String encryptedString = encrypted.base64; // ابتدا به بیس ۶۴ تبدیل میکنیم تا راحت تر جابجا شود

    // ۳. تبدیل خروجی رمز شده به Base32 (برای عبور از DNS)
    List<int> encryptedBytes = utf8.encode(encryptedString);
    String dnsSafePayload = base32.encode(Uint8List.fromList(encryptedBytes)).replaceAll('=', '').toLowerCase();

    // ۴. تقسیم به تکه‌های ۵۰ کاراکتری و ارسال (همان منطق فاز ۲)
    int chunkSize = 50;
    for (var i = 0; i < dnsSafePayload.length; i += chunkSize) {
      String chunk = dnsSafePayload.substring(i, i + chunkSize > dnsSafePayload.length ? dnsSafePayload.length : i + chunkSize);
      int index = (i / chunkSize).floor() + 1;
      int total = (dnsSafePayload.length / chunkSize).ceil();
      
      String packet = "$index-$total-$chunk.p99.peyk-d.ir";
      
      RawDatagramSocket.bind(InternetAddress.anyIPv4, 0).then((socket) {
        socket.send(utf8.encode(packet), InternetAddress("10.0.2.2"), 53);
        socket.close();
      });
      await Future.delayed(Duration(milliseconds: 100));
    }

    setState(() { _status = "🔐 Encrypted & Sent in ${(dnsSafePayload.length / chunkSize).ceil()} chunks"; });
  } catch (e) {
    setState(() { _status = "❌ Encryption Error: $e"; });
  }
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Peyk-D Emergency (Port 53)")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                labelText: "Enter Message",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => sendDnsMessage(_controller.text),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
              child: const Text("Send via DNS (UDP)"),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(10),
              color: Colors.grey[200],
              width: double.infinity,
              child: Text(
                "Status: $_status",
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}