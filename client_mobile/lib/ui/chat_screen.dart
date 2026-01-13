import 'dart:typed_data';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:base32/base32.dart';

// Import core layers
import '../core/protocol.dart';
import '../core/crypto.dart';
import '../core/dns_codec.dart';
import '../core/rx_assembly.dart';
import '../core/transport.dart';
import '../utils/id.dart';

enum NodeStatus { idle, polling, sending, success, error }

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  final Map<String, RxAssembly> _buffers = {};

  /// For ✓✓ mapping (sender side)
  /// key = "<sid>:<tot>"  where sid is me (sender id)
  final Map<String, int> _pendingDelivery = {};

  // Settings Variables
  String _myID = '';
  String _targetID = '';
  String _serverIP = PeykProtocol.defaultServerIP;
  String _baseDomain = PeykProtocol.baseDomain;
  NodeStatus _status = NodeStatus.idle;

  bool _pollingEnabled = true;
  bool _debugMode = false;
  int _pollMin = 20;
  int _pollMax = 40;
  int _retryCount = 1;

  Timer? _pollTimer;
  late AnimationController _glowCtrl;
  late Animation<double> _glowAnim;

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _loadSettings();
  }

  void _setupAnimations() {
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _glowAnim = Tween<double>(begin: 0.3, end: 0.8).animate(
      CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut),
    );
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _myID = prefs.getString('my_id') ?? IdUtils.generateRandomID();
      _targetID = prefs.getString('target_id') ?? '';
      _serverIP = prefs.getString('server_ip') ?? PeykProtocol.defaultServerIP;
      _baseDomain = prefs.getString('base_domain') ?? PeykProtocol.baseDomain;
      _pollMin = prefs.getInt('poll_min') ?? 20;
      _pollMax = prefs.getInt('poll_max') ?? 40;
      _retryCount = prefs.getInt('retry_count') ?? 1;
      _pollingEnabled = prefs.getBool('polling_enabled') ?? true;
      _debugMode = prefs.getBool('debug_mode') ?? false;

      if (prefs.getString('my_id') == null) prefs.setString('my_id', _myID);
    });
    _startPolling();
  }

  // ───────────────────────── SEND ─────────────────────────
  void _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || !IdUtils.isValid(_targetID)) return;

    _controller.clear();

    // UI: insert message immediately
    setState(() {
      _messages.insert(0, {
        "text": text,
        "status": "sending",
        "time": _getTime(),
      });
      _status = NodeStatus.sending;
    });

    final int messageIndex = 0; // چون insert(0) کردیم

    try {
      final encrypted = await PeykCrypto.encrypt(text);
      final b32 = base32.encode(encrypted).toLowerCase().replaceAll('=', '');
      final chunks = _makeChunks(b32);

      final transport = DnsTransport(_serverIP);

      // 🔑 کلیدی که با ACK2 سرور match می‌شود
      // server => ACK2-<sid>-<tot>
      final ackKey = "$_myID:${chunks.length}";

      // ذخیره برای ✓✓
      _pendingDelivery[ackKey] = messageIndex;

      // ✓ = server received
      setState(() {
        _messages[messageIndex]["status"] = "sent";
      });

      for (int i = 0; i < chunks.length; i++) {
        final label =
            "${i + 1}-${chunks.length}-$_myID-$_targetID-${chunks[i]}";

        for (int r = 0; r <= _retryCount; r++) {
          await transport.sendOnly(
            DnsCodec.buildQuery(
              "$label.$_baseDomain",
              qtype: PeykProtocol.qtypeA,
            ),
          );
        }
      }

      setState(() => _status = NodeStatus.success);
    } catch (e) {
      if (_debugMode) print("❌ Send Error: $e");
      setState(() => _status = NodeStatus.error);
    }

    Future.delayed(
      const Duration(seconds: 2),
      () => setState(() => _status = NodeStatus.idle),
    );
  }


  List<String> _makeChunks(String data) {
    // keep your original chunk size
    const int size = 30;
    final List<String> chunks = [];
    for (var i = 0; i < data.length; i += size) {
      chunks.add(data.substring(i, min(i + size, data.length)));
    }
    return chunks;
  }

  // ───────────────────────── POLLING ─────────────────────────
  void _startPolling() {
    _pollTimer?.cancel();
    if (!_pollingEnabled) return;

    _pollTimer = Timer.periodic(
      Duration(
        seconds: _pollMin + Random().nextInt(max(1, _pollMax - _pollMin + 1)),
      ),
      (timer) async {
        await _fetchBuffer();
      },
    );
  }

  // Drain server queue fast
  Future<void> _fetchBuffer() async {
    if (_status != NodeStatus.idle && _status != NodeStatus.polling) return;
    setState(() => _status = NodeStatus.polling);

    final transport = DnsTransport(_serverIP);
    bool hasMore = true;

    while (hasMore) {
      final query = DnsCodec.buildQuery(
        "v1.sync.$_myID.$_baseDomain",
        qtype: PeykProtocol.qtypeTXT, // IMPORTANT: polling must be TXT
      );

      final response = await transport.sendAndReceive(query);

      if (response == null) {
        hasMore = false;
        break;
      }

      final txt = DnsCodec.extractTxt(response);
      if (txt == null || txt == "NOP") {
        hasMore = false;
        break;
      }

      if (_debugMode) {
        print("DEBUG: POLL TXT => $txt");
      }

      // ✅ Fix regression: ACK2 must not go through chunk parser
      if (txt.startsWith("ACK2-")) {
        _handleDeliveryAck(txt);
        await Future.delayed(const Duration(milliseconds: 200));
        continue;
      }

      _handleIncomingChunk(txt);
      await Future.delayed(const Duration(milliseconds: 300));
    }

    setState(() => _status = NodeStatus.idle);
  }

  // Handle ✓✓ from server for messages we sent
  void _handleDeliveryAck(String txt) {
    final parts = txt.split("-");
    if (parts.length != 3) return;

    final sid = parts[1];
    final tot = parts[2];
    final key = "$sid:$tot";

    final idx = _pendingDelivery[key];
    if (idx != null && idx < _messages.length) {
      setState(() {
        _messages[idx]["status"] = "delivered"; // ✓✓
      });
      _pendingDelivery.remove(key);
    }
  }

  // ───────────────────────── RX CHUNKS ─────────────────────────
  void _handleIncomingChunk(String txt) async {
    try {
      // format: idx-tot-sid-rid-payload
      final parts = txt.split('-');
      if (parts.length < 5) return;

      final idx = int.parse(parts[0]);
      final tot = int.parse(parts[1]);
      final sid = parts[2];
      final rid = parts[3];
      final payload = parts.sublist(4).join('-');

      // accept only if for us
      if (rid != _myID) return;

      final key = "$sid:$rid:$tot";
      _buffers.putIfAbsent(key, () => RxAssembly(sid, tot));
      _buffers[key]!.addPart(idx, payload);

      if (_debugMode) {
        print("DEBUG: Received Chunk $idx/$tot from $sid");
      }

      if (_buffers[key]!.isComplete) {
        final fullB32 = _buffers[key]!.assemble();
        _buffers.remove(key);

        // normalize base32 for decoder
        String readyToDecode = fullB32.toUpperCase();
        while (readyToDecode.length % 8 != 0) {
          readyToDecode += '=';
        }

        final Uint8List decodedBytes =
            Uint8List.fromList(base32.decode(readyToDecode));

        final decrypted = await PeykCrypto.decrypt(decodedBytes);

        setState(() {
          _messages.insert(0, {
            "text": decrypted,
            "status": "received",
            "from": sid,
            "time": _getTime(),
          });
        });

        if (_debugMode) print("✅ Success: Message decrypted and shown.");

        // ✅ Send ACK2 back to server to confirm delivery (✓✓ for sender)
        final transport = DnsTransport(_serverIP);
        await transport.sendOnly(
          DnsCodec.buildQuery(
            "ack2-$sid-$tot.$_baseDomain",
            qtype: PeykProtocol.qtypeA,
          ),
        );
      }
    } catch (e) {
      if (_debugMode) print("❌ Chunk Parsing Error: $e");
    }
  }

  String _getTime() =>
      "${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}";

  // ───────────────────────── UI ─────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "PEYK-D TERMINAL",
          style: TextStyle(letterSpacing: 3, fontSize: 12, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.settings, size: 20), onPressed: _showSettings),
        ],
      ),
      body: Column(
        children: [
          _buildStatusLine(),
          Expanded(child: _buildChatList()),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildStatusIcon(String status) {
    switch (status) {
      case "sending":
        return const Icon(Icons.check, size: 14, color: Colors.white24);
      case "sent":
        return const Icon(Icons.check, size: 14, color: Colors.white54);
      case "delivered":
        return const Icon(Icons.done_all, size: 14, color: Color(0xFF00A884));
      default:
        return const SizedBox.shrink();
    }
  }
  
  Widget _buildStatusLine() {
    return Container(
      width: double.infinity,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
      child: Text(
        "SYS_STATUS: ${_status.name.toUpperCase()} | NODE: $_myID",
        style: const TextStyle(
          color: Color(0xFF00A884),
          fontSize: 9,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  Widget _buildChatList() {
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.all(16),
      itemCount: _messages.length,
      itemBuilder: (context, index) => _buildMessageBubble(_messages[index]),
    );
  }

  Widget _buildMessageBubble(Map<String, dynamic> msg) {
    bool isRx = msg["status"] == "received";
    return Align(
      alignment: isRx ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isRx ? const Color(0xFF1F2C34) : const Color(0xFF005C4B),
          borderRadius: BorderRadius.circular(15).copyWith(
            bottomLeft: isRx ? Radius.zero : const Radius.circular(15),
            bottomRight: isRx ? const Radius.circular(15) : Radius.zero,
          ),
        ),
        child: Column(
          crossAxisAlignment: isRx ? CrossAxisAlignment.start : CrossAxisAlignment.end,
          children: [
            if (isRx)
              Text(
                msg["from"],
                style: const TextStyle(
                  color: Color(0xFF00A884),
                  fontSize: 8,
                  fontWeight: FontWeight.bold,
                ),
              ),
            Text(msg["text"], style: const TextStyle(color: Colors.white)),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  msg["time"],
                  style: const TextStyle(color: Colors.white30, fontSize: 8),
                ),
                const SizedBox(width: 4),
                if (msg["status"] != "received")
                  _buildStatusIcon(msg["status"]),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 30),
      color: const Color(0xFF182229),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: _targetID.isEmpty ? "Set Target in Settings" : "Message to $_targetID...",
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: const Color(0xFF2A3942),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          CircleAvatar(
            backgroundColor: const Color(0xFF00A884),
            child: IconButton(
              icon: const Icon(Icons.send, color: Colors.white),
              onPressed: _sendMessage,
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────── SETTINGS ─────────────────────────
// ───────────────────────── SETTINGS ─────────────────────────
  void _showSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final domainCtrl = TextEditingController(text: _baseDomain);
    final targetCtrl = TextEditingController(text: _targetID);
    final ipCtrl = TextEditingController(text: _serverIP);
    final pollMinCtrl = TextEditingController(text: _pollMin.toString());
    final pollMaxCtrl = TextEditingController(text: _pollMax.toString());
    final retryCtrl = TextEditingController(text: _retryCount.toString());

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setL) => AlertDialog(
          backgroundColor: const Color(0xFF182229),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: const Color(0xFF00A884).withOpacity(0.3), width: 1),
          ),
          title: const Text(
            "NODE CONFIGURATION",
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 2,
              fontWeight: FontWeight.bold,
              color: Color(0xFF00A884),
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: _glowAnim,
                  builder: (context, _) => Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(
                        color: const Color(0xFF00A884).withOpacity(_glowAnim.value),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF00A884).withOpacity(_glowAnim.value * 0.3),
                          blurRadius: 15,
                          spreadRadius: 1,
                        )
                      ],
                    ),
                    child: Column(
                      children: [
                        const Text("YOUR UNIQUE ADDRESS",
                            style: TextStyle(fontSize: 8, color: Colors.white38)),
                        const SizedBox(height: 8),
                        SelectableText(
                          _myID,
                          style: const TextStyle(
                            fontSize: 22,
                            letterSpacing: 4,
                            fontFamily: 'monospace',
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 15),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.code, size: 10, color: Colors.white24),
                    SizedBox(width: 5),
                    Text(
                      "Arash, MEL - Jan2026",
                      style: TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: Colors.white54,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
                const Divider(color: Colors.white10, height: 25),

                _buildSettingField(targetCtrl, "Target Node ID", Icons.person_pin, "abcde"),
                _buildSettingField(ipCtrl, "Relay Server IP", Icons.lan, "1.2.3.4"),
                _buildSettingField(domainCtrl, "Base Domain", Icons.dns, "p99.peyk-d.ir"), // اضافه شد
                
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: _buildSettingField(pollMinCtrl, "Min Poll", Icons.timer_outlined, "20", isNum: true)),
                    const SizedBox(width: 10),
                    Expanded(child: _buildSettingField(pollMaxCtrl, "Max Poll", Icons.timer, "40", isNum: true)),
                  ],
                ),
                
                _buildSettingField(retryCtrl, "Retries", Icons.repeat, "1", isNum: true),
                
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text("Active Polling", style: TextStyle(fontSize: 12, color: Colors.white70)),
                  value: _pollingEnabled,
                  activeColor: const Color(0xFF00A884),
                  onChanged: (v) => setL(() => _pollingEnabled = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text("Debug Mode", style: TextStyle(fontSize: 12, color: Colors.white70)),
                  value: _debugMode,
                  activeColor: Colors.orange,
                  onChanged: (v) => setL(() => _debugMode = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("DISCARD", style: TextStyle(color: Colors.white30)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00A884),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () async {
                await prefs.setString('target_id', targetCtrl.text.trim());
                await prefs.setString('server_ip', ipCtrl.text.trim());
                await prefs.setString('base_domain', domainCtrl.text.trim()); // اضافه شد
                await prefs.setInt('poll_min', int.tryParse(pollMinCtrl.text) ?? 20);
                await prefs.setInt('poll_max', int.tryParse(pollMaxCtrl.text) ?? 40);
                await prefs.setInt('retry_count', int.tryParse(retryCtrl.text) ?? 1);
                await prefs.setBool('polling_enabled', _pollingEnabled);
                await prefs.setBool('debug_mode', _debugMode);
                _loadSettings();
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text("APPLY", style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingField(
    TextEditingController ctrl,
    String label,
    IconData icon,
    String hint, {
    bool isNum = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextField(
        controller: ctrl,
        keyboardType: isNum ? TextInputType.number : TextInputType.text,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon, size: 18, color: const Color(0xFF00A884)),
          labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
          filled: true,
          fillColor: Colors.black26,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _glowCtrl.dispose();
    _controller.dispose();
    super.dispose();
  }
}
