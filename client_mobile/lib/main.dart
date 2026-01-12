import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:base32/base32.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const PeykDApp());

class PeykDApp extends StatelessWidget {
  const PeykDApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.blueGrey, useMaterial3: true),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  
  // مقادیر شبکه (که از تنظیمات خوانده می‌شوند)
  String _serverIP = "10.0.2.2";
  String _baseDomain = "p99.peyk-d.ir";
  String _status = "Ready";

  // تنظیمات امنیتی AES
  final key = enc.Key.fromUtf8('my32characterslongsecretkey12345');
  final iv = enc.IV.fromUtf8('1212312312312312');

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  // بارگذاری تنظیمات از حافظه گوشی
  _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _serverIP = prefs.getString('server_ip') ?? "10.0.2.2";
      _baseDomain = prefs.getString('base_domain') ?? "p99.peyk-d.ir";
    });
  }

  // نمایش دیالوگ تنظیمات
  void _showSettingsDialog() {
    TextEditingController ipCtrl = TextEditingController(text: _serverIP);
    TextEditingController domainCtrl = TextEditingController(text: _baseDomain);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Network Settings"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: ipCtrl, decoration: const InputDecoration(labelText: "Server IP")),
            TextField(controller: domainCtrl, decoration: const InputDecoration(labelText: "Base Domain")),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('server_ip', ipCtrl.text);
              await prefs.setString('base_domain', domainCtrl.text);
              _loadSettings();
              Navigator.pop(context);
            },
            child: const Text("Save"),
          ),
        ],
      ),
    );
  }

  // تابع ارسال پیام رمزنگاری شده و تکه‌تکه شده
  void _sendMessage() async {
    String text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _messages.insert(0, {"text": text, "sender": "user"});
      _status = "Encrypting...";
    });
    _controller.clear();

    try {
      // ۱. رمزنگاری AES
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
      final encrypted = encrypter.encrypt(text, iv: iv);
      
      // ۲. تبدیل به Base32 برای DNS
      String encryptedBase64 = encrypted.base64;
      String dnsSafePayload = base32.encode(Uint8List.fromList(utf8.encode(encryptedBase64))).replaceAll('=', '').toLowerCase();

      // ۳. تقسیم به تکه‌های ۵۰ کاراکتری
      int chunkSize = 50;
      int totalChunks = (dnsSafePayload.length / chunkSize).ceil();

      for (var i = 0; i < dnsSafePayload.length; i += chunkSize) {
        String chunk = dnsSafePayload.substring(i, i + chunkSize > dnsSafePayload.length ? dnsSafePayload.length : i + chunkSize);
        int index = (i / chunkSize).floor() + 1;
        
        // استفاده از دامنه تنظیم شده توسط کاربر
        String fullDomain = "$index-$totalChunks-$chunk.$_baseDomain";

        RawDatagramSocket.bind(InternetAddress.anyIPv4, 0).then((socket) {
          // ارسال به IP تنظیم شده توسط کاربر
          socket.send(utf8.encode(fullDomain), InternetAddress(_serverIP), 53);
          socket.close();
        });
        
        await Future.delayed(const Duration(milliseconds: 150));
      }
      
      setState(() => _status = "Sent ✅ to $_serverIP");
    } catch (e) {
      setState(() => _status = "Error ❌: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Peyk-D Secure Chat", style: TextStyle(color: Colors.white)),
        centerTitle: false, // فضای بیشتر برای آیکون‌ها
        backgroundColor: Colors.blueGrey[900],
        elevation: 4,
        actions: [
          // دکمه تنظیمات که حالا به درستی نمایش داده می‌شود
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white, size: 28),
            onPressed: _showSettingsDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                return Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blueGrey[700],
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(15),
                        topRight: Radius.circular(15),
                        bottomLeft: Radius.circular(15),
                      ),
                    ),
                    child: Text(_messages[index]["text"]!, style: const TextStyle(color: Colors.white)),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(_status, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)]),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(hintText: "Type a message...", border: InputBorder.none),
                  ),
                ),
                IconButton(icon: const Icon(Icons.send, color: Colors.blueGrey), onPressed: _sendMessage),
              ],
            ),
          ),
        ],
      ),
    );
  }
}