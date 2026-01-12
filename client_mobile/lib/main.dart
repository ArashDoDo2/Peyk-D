import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:base32/base32.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';

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
  final _secureStorage = const FlutterSecureStorage();
  
  String _serverIP = "10.0.2.2";
  String _baseDomain = "p99.peyk-d.ir";
  String _encryptionKey = "my32characterslongsecretkey12345"; 
  String _status = "Ready";

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final sKey = await _secureStorage.read(key: 'enc_key');
    setState(() {
      _serverIP = prefs.getString('server_ip') ?? "10.0.2.2";
      _baseDomain = prefs.getString('base_domain') ?? "p99.peyk-d.ir";
      _encryptionKey = sKey ?? "my32characterslongsecretkey12345";
    });
  }

  Uint8List _buildRfc1035Query(String fqdn, int txId) {
    final builder = BytesBuilder();
    builder.addByte((txId >> 8) & 0xFF);
    builder.addByte(txId & 0xFF);
    builder.add([0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);

    for (var part in fqdn.split('.')) {
      if (part.isNotEmpty) {
        final bytes = utf8.encode(part);
        builder.addByte(bytes.length);
        builder.add(bytes);
      }
    }
    builder.addByte(0x00);
    builder.add([0x00, 0x01, 0x00, 0x01]);
    return builder.toBytes();
  }

  void _sendMessage() async {
    String text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _messages.insert(0, {"text": text, "sender": "user"});
      _status = "Processing...";
    });
    _controller.clear();

    RawDatagramSocket? socket;
    try {
      final secureRand = Random.secure();
      
      // ۱. رمزنگاری AES-256-GCM
      final algorithm = AesGcm.with256bits();
      final secretKey = SecretKey(utf8.encode(_encryptionKey));
      final nonce = algorithm.newNonce();
      
      // توجه: در این نسخه framing (مثل msgId داخلی) را حذف کردیم چون سرور از Label استفاده می‌کند
      final secretBox = await algorithm.encrypt(utf8.encode(text), secretKey: secretKey, nonce: nonce);
      
      // ترکیب نهایی: Nonce(12) + Tag(16) + Ciphertext
      final combined = Uint8List.fromList(secretBox.nonce + secretBox.mac.bytes + secretBox.cipherText);
      String fullPayload = base32.encode(combined).replaceAll('=', '').toLowerCase();

      // تولید msgId کوتاه برای استفاده در Label (جهت Session Tracking در سرور)
      String msgLabelId = (secureRand.nextInt(9000) + 1000).toString(); 

      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      
      // ۲. منطق Chunking دو مرحله‌ای (برای اطمینان از طول دقیق Label)
      // فرمت: index-total-msgId-payload
      int estimatedTotal = (fullPayload.length / 30).ceil(); 
      List<String> finalChunks = [];
      int ptr = 0;

      while (ptr < fullPayload.length) {
        String prefix = "${finalChunks.length + 1}-$estimatedTotal-$msgLabelId-";
        int available = 63 - utf8.encode(prefix).length;
        
        int end = (ptr + available > fullPayload.length) ? fullPayload.length : ptr + available;
        finalChunks.add(fullPayload.substring(ptr, end));
        ptr = end;
      }

      int finalTotal = finalChunks.length;
      
      // ۳. ارسال پکت‌ها
      for (int i = 0; i < finalTotal; i++) {
        String label = "${i + 1}-$finalTotal-$msgLabelId-${finalChunks[i]}";
        String fqdn = "$label.$_baseDomain";
        
        // چک نهایی طول طبق RFC
        if (utf8.encode(label).length > 63) throw Exception("Label too long");

        int txId = secureRand.nextInt(65535);
        socket.send(_buildRfc1035Query(fqdn, txId), InternetAddress(_serverIP), 53);
        
        setState(() => _status = "Sent ${i+1}/$finalTotal");
        await Future.delayed(const Duration(milliseconds: 60));
      }
      
      setState(() => _status = "Success: Sent via DNS");
    } catch (e) {
      setState(() => _status = "Error: $e");
    } finally {
      socket?.close();
    }
  }

  // --- UI بخش تنظیمات ---
  void _showSettingsDialog() {
    TextEditingController ipCtrl = TextEditingController(text: _serverIP);
    TextEditingController domCtrl = TextEditingController(text: _baseDomain);
    TextEditingController keyCtrl = TextEditingController(text: _encryptionKey);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Peyk-D Config"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: ipCtrl, decoration: const InputDecoration(labelText: "Server IP")),
            TextField(controller: domCtrl, decoration: const InputDecoration(labelText: "Base Domain")),
            TextField(controller: keyCtrl, decoration: const InputDecoration(labelText: "32-char AES Key")),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () async {
              if (utf8.encode(keyCtrl.text).length != 32) return;
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('server_ip', ipCtrl.text);
              await prefs.setString('base_domain', domCtrl.text);
              await _secureStorage.write(key: 'enc_key', value: keyCtrl.text);
              _loadSettings();
              Navigator.pop(context);
            },
            child: const Text("Save"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Peyk-D Client"), backgroundColor: Colors.blueGrey[900], actions: [
        IconButton(icon: const Icon(Icons.settings), onPressed: _showSettingsDialog)
      ]),
      body: Column(children: [
        Expanded(child: ListView.builder(reverse: true, itemCount: _messages.length, itemBuilder: (c, i) => 
          ListTile(title: Text(_messages[i]["text"]!, textAlign: TextAlign.right)))),
        Container(color: Colors.black12, child: Text(_status, style: const TextStyle(fontSize: 11))),
        Padding(padding: const EdgeInsets.all(8.0), child: Row(children: [
          Expanded(child: TextField(controller: _controller, decoration: const InputDecoration(hintText: "Secure..."))),
          IconButton(icon: const Icon(Icons.send), onPressed: _sendMessage)
        ]))
      ]),
    );
  }
}