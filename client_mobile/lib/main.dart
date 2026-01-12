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
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFF00A884),
        scaffoldBackgroundColor: const Color(0xFF0B141A),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF182229), elevation: 0),
        useMaterial3: true,
      ),
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
  final List<Map<String, dynamic>> _messages = [];
  final _secureStorage = const FlutterSecureStorage();
  
  String _serverIP = "10.0.2.2";
  String _baseDomain = "p99.peyk-d.ir";
  String _encryptionKey = "my32characterslongsecretkey12345";
  String _status = "IDLE / SECURE";

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

  Future<void> _saveSettings(String ip, String domain, String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_ip', ip);
    await prefs.setString('base_domain', domain);
    await _secureStorage.write(key: 'enc_key', value: key);
    await _loadSettings();
    setState(() => _status = "CONFIG UPDATED");
  }

  Color _getStatusColor() {
    if (_status.contains("SUCCESS") || _status.contains("IDLE")) return const Color(0xFF81C784);
    if (_status.contains("TRANSMITTING")) return Colors.amber[300]!;
    if (_status.contains("ERROR") || _status.contains("FAILED")) return Colors.red[300]!;
    return Colors.white24;
  }

  void _sendMessage() async {
    String text = _controller.text.trim();
    if (text.isEmpty) return;

    final String localId = DateTime.now().millisecondsSinceEpoch.toString();
    final String timeStr = "${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}";
    
    setState(() {
      _messages.insert(0, {"type": "user", "text": text, "status": "sending", "id": localId, "time": timeStr});
      _status = "TRANSMITTING DATA...";
    });
    _controller.clear();

    RawDatagramSocket? socket;
    try {
      final secureRand = Random.secure();
      final algorithm = AesGcm.with256bits();
      final secretKey = SecretKey(utf8.encode(_encryptionKey));
      final nonce = algorithm.newNonce();
      
      // ۱. رمزنگاری واقعی AES-GCM
      final secretBox = await algorithm.encrypt(utf8.encode(text), secretKey: secretKey, nonce: nonce);
      final combined = Uint8List.fromList(secretBox.nonce + secretBox.mac.bytes + secretBox.cipherText);
      String fullPayload = base32.encode(combined).replaceAll('=', '').toLowerCase();
      String msgLabelId = (secureRand.nextInt(9000) + 1000).toString();

      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = socket?.receive();
          if (dg != null && _verifyAck(dg.data)) {
            setState(() {
              int idx = _messages.indexWhere((m) => m["id"] == localId);
              if (idx != -1) {
                _messages[idx]["status"] = "delivered";
                _messages.insert(0, {"type": "system", "text": "ACK RECEIVED FROM SERVER"});
              }
              _status = "SUCCESS: PACKET DELIVERED";
            });
          }
        }
      });

      // ۲. ارسال واقعی چانک‌ها
      List<String> chunks = _generateChunks(fullPayload, msgLabelId);
      for (int i = 0; i < chunks.length; i++) {
        String label = "${i + 1}-${chunks.length}-$msgLabelId-${chunks[i]}";
        int txId = secureRand.nextInt(65535);
        socket.send(_buildRfc1035(label + "." + _baseDomain, txId), InternetAddress(_serverIP), 53);
        await Future.delayed(Duration(milliseconds: i == chunks.length - 1 ? 800 : 150));
      }
    } catch (e) {
      setState(() => _status = "ERROR: $e");
    } finally {
      Future.delayed(const Duration(seconds: 5), () => socket?.close());
    }
  }

  List<String> _generateChunks(String p, String id) {
    List<String> c = []; int ptr = 0;
    while (ptr < p.length) {
      int av = 63 - utf8.encode("255-255-$id-").length;
      int end = (ptr + av > p.length) ? p.length : ptr + av;
      c.add(p.substring(ptr, end)); ptr = end;
    }
    return c;
  }

  Uint8List _buildRfc1035(String f, int id) {
    final b = BytesBuilder();
    b.addByte((id >> 8) & 0xFF); b.addByte(id & 0xFF);
    b.add([0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
    for (var p in f.split('.')) { if (p.isNotEmpty) { b.addByte(p.length); b.add(utf8.encode(p)); } }
    b.add([0x00, 0x00, 0x01, 0x00, 0x01]);
    return b.toBytes();
  }

  bool _verifyAck(Uint8List d) => d.length >= 16 && d.sublist(d.length - 4).join('.') == "1.2.3.4";

  // دکمه تنظیمات که حالا واقعاً کار می‌کند
  void _showSettings() {
    final ipCtrl = TextEditingController(text: _serverIP);
    final domCtrl = TextEditingController(text: _baseDomain);
    final keyCtrl = TextEditingController(text: _encryptionKey);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF182229),
        title: const Text("Node Configuration", style: TextStyle(fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: ipCtrl, decoration: const InputDecoration(labelText: "Server IP")),
              TextField(controller: domCtrl, decoration: const InputDecoration(labelText: "Base Domain")),
              TextField(controller: keyCtrl, decoration: const InputDecoration(labelText: "AES Key (32 chars)")),
              const Padding(
                padding: EdgeInsets.only(top: 15),
                child: Text("⚠️ Changes affect packet encryption.", style: TextStyle(color: Colors.redAccent, fontSize: 10)),
              )
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("CANCEL")),
          ElevatedButton(
            onPressed: () {
              _saveSettings(ipCtrl.text, domCtrl.text, keyCtrl.text);
              Navigator.pop(context);
            },
            child: const Text("SAVE"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(45.0),
        child: AppBar(
          title: const Text("PEYK-D TUNNEL", style: TextStyle(letterSpacing: 2, fontSize: 11, fontWeight: FontWeight.w900)),
          centerTitle: true,
          actions: [IconButton(icon: const Icon(Icons.tune, size: 18), onPressed: _showSettings)],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty 
              ? _buildEmptyState()
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final msg = _messages[index];
                    if (msg["type"] == "system") return _buildSystemEvent(msg["text"]);
                    return _buildChatBubble(msg);
                  },
                ),
          ),
          _buildSmartLog(),
          _buildInput(),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.radar, size: 40, color: Colors.white.withOpacity(0.1)),
          const SizedBox(height: 10),
          const Text("Emergency Channel Operational", style: TextStyle(color: Colors.white24, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _buildSystemEvent(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        const Expanded(child: Divider(color: Colors.white10)),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text("[!] $text", style: const TextStyle(color: Colors.white24, fontSize: 8, fontFamily: 'monospace'))),
        const Expanded(child: Divider(color: Colors.white10)),
      ]),
    );
  }

  Widget _buildSmartLog() {
    return Container(
      width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 12),
      color: Colors.black,
      child: Row(children: [
        const Text("SYS_LOG: ", style: TextStyle(color: Colors.white12, fontSize: 8, fontFamily: 'monospace')),
        Text(_status, style: TextStyle(color: _getStatusColor(), fontSize: 8, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
      ]),
    );
  }

  Widget _buildChatBubble(Map<String, dynamic> msg) {
    bool isSending = msg["status"] == "sending";
    bool isDelivered = msg["status"] == "delivered";
    return Align(
      alignment: Alignment.centerRight,
      child: Opacity(
        opacity: isSending ? 0.6 : 1.0,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xFF005C4B), borderRadius: BorderRadius.circular(12).copyWith(bottomRight: const Radius.circular(2))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(msg["text"], style: const TextStyle(fontSize: 14.5)),
            const SizedBox(height: 2),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text(msg["time"], style: TextStyle(fontSize: 7.5, color: Colors.white.withOpacity(0.25))),
              const SizedBox(width: 4),
              if (isSending) const SizedBox(width: 8, height: 8, child: CircularProgressIndicator(strokeWidth: 1, color: Colors.white24))
              else Icon(Icons.done_all, size: 12, color: isDelivered ? const Color(0xFF53BDEB) : Colors.white10),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _buildInput() {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 15),
      color: const Color(0xFF182229),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _controller,
            decoration: InputDecoration(
              hintText: "Enter secure packet...",
              fillColor: const Color(0xFF2A3942), filled: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
            ),
          ),
        ),
        const SizedBox(width: 8),
        CircleAvatar(
          radius: 20, backgroundColor: const Color(0xFF00A884),
          child: IconButton(icon: const Icon(Icons.send, size: 16, color: Colors.white), onPressed: _sendMessage),
        ),
      ]),
    );
  }
}