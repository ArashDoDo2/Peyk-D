import 'dart:io';
import 'dart:convert';
import 'dart:typed_data'; // حتماً این خط را اضافه کنید
import 'package:flutter/material.dart';
import 'package:base32/base32.dart';

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
    const String hostIP = "10.0.2.2"; 
    const int port = 53; 

    // ۱. تبدیل متن به بایت‌های UTF-8 (برای پشتیبانی از فارسی)
    List<int> messageBytes = utf8.encode(message);

    // ۲. کدگذاری به Base32
    String encoded = base32.encode(Uint8List.fromList(messageBytes));
    
    // ۳. حذف علامت '=' (Padding) چون در DNS مجاز نیست و کوچک کردن حروف
    String dnsSafePayload = encoded.replaceAll('=', '').toLowerCase();
    
    // ۴. ساخت ساب‌دامنه نهایی
    String fullDomain = "$dnsSafePayload.p99.peyk-d.ir";

    RawDatagramSocket.bind(InternetAddress.anyIPv4, 0).then((RawDatagramSocket socket) {
      socket.send(utf8.encode(fullDomain), InternetAddress(hostIP), port);
      socket.close();
      
      setState(() {
        _status = "✅ Encoded & Sent: $fullDomain";
      });
    });
  } catch (e) {
    setState(() {
      _status = "❌ Error: $e";
    });
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