import 'dart:io';
import 'package:flutter/material.dart';
import 'dart:convert';

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
      // 1. آدرس جادویی برای دسترسی به ویندوز از داخل امولاتور
      const String hostIP = "10.0.2.2"; 
      const int port = 53; 

      // 2. ساخت ساب‌دامنه (طبق استراتژی پروژه: حروف کوچک)
      String payload = message.toLowerCase().trim().replaceAll(' ', '-');
      String fullDomain = "$payload.p99.peyk-d.ir";

      // 3. باز کردن سوکت و ارسال پکت خام
      RawDatagramSocket.bind(InternetAddress.anyIPv4, 0).then((RawDatagramSocket socket) {
        // تبدیل متن به بایت و ارسال
        socket.send(utf8.encode(fullDomain), InternetAddress(hostIP), port);
        socket.close(); // بستن بلافاصله سوکت بعد از ارسال
        
        setState(() {
          _status = "✅ Sent to 10.0.2.2:53 -> $fullDomain";
        });
        print("UDP Packet Dispatched: $fullDomain");
      });

    } catch (e) {
      setState(() {
        _status = "❌ Socket Error: $e";
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