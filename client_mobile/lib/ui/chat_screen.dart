import 'dart:typed_data';
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:base32/base32.dart';

// Core layers
import '../core/protocol.dart';
import '../core/crypto.dart';
import '../core/rx_assembly.dart';
import '../core/transport.dart';
import '../utils/id.dart';

enum NodeStatus { idle, polling, sending, success, error }

class _RxBufferState {
  final RxAssembly asm;
  DateTime createdAt;
  DateTime lastUpdatedAt;

  _RxBufferState(this.asm)
      : createdAt = DateTime.now(),
        lastUpdatedAt = DateTime.now();
}

class ChatScreen extends StatefulWidget {
  final String targetId;
  final String? displayName;

  const ChatScreen({super.key, required this.targetId, this.displayName});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  final Map<String, _RxBufferState> _buffers = {};
  final Map<String, int> _pendingDelivery = {};
  final Map<String, DateTime> _recentRx = {};
  Map<String, String> _contactNames = {};
  final ScrollController _chatScrollCtrl = ScrollController();
  bool _showJumpToBottom = false;
  static const String _unreadKey = 'contacts_unread';

  String _myID = '';
  String _targetID = '';
  String _serverIP = PeykProtocol.defaultServerIP;
  String _baseDomain = PeykProtocol.baseDomain;
  NodeStatus _status = NodeStatus.idle;

  bool _pollingEnabled = true;
  bool _debugMode = false;
  bool _fallbackEnabled = false;
  bool _useDirectServer = false;
  bool _sendViaAAAA = false;
  int _pollMin = 20;
  int _pollMax = 40;
  int _retryCount = 1;

  Timer? _pollTimer;
  late AnimationController _glowCtrl;
  late Animation<double> _glowAnim;

  static const Duration _bufferTtl = Duration(seconds: 90);
  static const int _historyMax = 200;
  static const Duration _rxDedupTtl = Duration(minutes: 10);
  static const Color _accent = Color(0xFF00A884);
  static const Color _accentAlt = Color(0xFF25D366);
  static const Color _panel = Color(0xFF111B21);
  static const Color _panelAlt = Color(0xFF0B141A);
  static const Color _textDim = Color(0xFF8696A0);

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _loadSettings();
    _chatScrollCtrl.addListener(_handleChatScroll);
  }

  void _setupAnimations() {
    _glowCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _glowAnim = Tween<double>(begin: 0.3, end: 0.8).animate(CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut));
  }

  void _handleChatScroll() {
    if (!_chatScrollCtrl.hasClients) return;
    final shouldShow = _chatScrollCtrl.offset > 120;
    if (shouldShow != _showJumpToBottom) {
      setState(() => _showJumpToBottom = shouldShow);
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final namesRaw = prefs.getString('contacts_names');
    Map<String, String> names = {};
    if (namesRaw != null && namesRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(namesRaw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final key = entry.key.toString().toLowerCase();
            final val = entry.value.toString();
            if (val.isNotEmpty) names[key] = val;
          }
        }
      } catch (_) {
        // ignore bad names
      }
    }
    setState(() {
      _myID = prefs.getString('my_id') ?? IdUtils.generateRandomID();
      _targetID = widget.targetId;
      _serverIP = prefs.getString('server_ip') ?? PeykProtocol.defaultServerIP;
      _baseDomain = prefs.getString('base_domain') ?? PeykProtocol.baseDomain;
      _pollMin = prefs.getInt('poll_min') ?? 20;
      _pollMax = prefs.getInt('poll_max') ?? 40;
      _retryCount = prefs.getInt('retry_count') ?? 1;
      _pollingEnabled = prefs.getBool('polling_enabled') ?? true;
      _debugMode = prefs.getBool('debug_mode') ?? false;
      _fallbackEnabled = prefs.getBool('fallback_enabled') ?? false;
      _useDirectServer = prefs.getBool('use_direct_server') ?? false;
      _sendViaAAAA = prefs.getBool('send_via_aaaa') ?? false;
      _contactNames = names;

      if (prefs.getString('my_id') == null) prefs.setString('my_id', _myID);
    });
    await _loadHistory();
    await _clearUnreadForTarget();
    _startPolling();
  }

  String _historyKey() => "chat_history_${_myID.toLowerCase()}_${_targetID.toLowerCase()}";

  String _historyKeyForTarget(String targetId) => "chat_history_${_myID.toLowerCase()}_${targetId.toLowerCase()}";

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey());
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final items = decoded.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
        setState(() {
          _messages
            ..clear()
            ..addAll(items);
        });
      }
    } catch (_) {
      // ignore bad history
    }
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final data = _messages.take(_historyMax).toList();
    await prefs.setString(_historyKey(), jsonEncode(data));
  }

  Future<void> _appendToHistoryForTarget(String targetId, Map<String, dynamic> msg) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _historyKeyForTarget(targetId);
    final raw = prefs.getString(key);
    List<Map<String, dynamic>> items = [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          items = decoded.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
        }
      } catch (_) {
        // ignore bad history
      }
    }
    items.insert(0, msg);
    final data = items.take(_historyMax).toList();
    await prefs.setString(key, jsonEncode(data));
  }

  Future<void> _incrementUnread(String targetId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_unreadKey);
    Map<String, int> counts = {};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final key = entry.key.toString().toLowerCase();
            final val = int.tryParse(entry.value.toString()) ?? 0;
            counts[key] = val;
          }
        }
      } catch (_) {
        // ignore bad counts
      }
    }
    final key = targetId.toLowerCase();
    counts[key] = (counts[key] ?? 0) + 1;
    await prefs.setString(_unreadKey, jsonEncode(counts));
  }

  Future<void> _clearUnreadForTarget() async {
    if (_targetID.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_unreadKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.remove(_targetID.toLowerCase());
        await prefs.setString(_unreadKey, jsonEncode(decoded));
      }
    } catch (_) {
      // ignore bad counts
    }
  }

  // ───────────────────────── SEND ─────────────────────────

  void _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || !IdUtils.isValid(_targetID)) return;
    _controller.clear();

    setState(() {
      _messages.insert(0, {"text": text, "status": "sending", "time": _getTime()});
      _status = NodeStatus.sending;
    });
    await _saveHistory();

    try {
      final encrypted = await PeykCrypto.encrypt(text);
      final b32 = base32.encode(encrypted).toLowerCase().replaceAll('=', '');
      final chunks = _makeChunks(b32);
      final transport = DnsTransport(serverIP: _useDirectServer ? _serverIP : null);
      final mid = IdUtils.generateRandomID();

      final ackKey = "${_myID.toLowerCase()}:${chunks.length}:$mid";
      _messages[0]["deliveryKey"] = ackKey;
      _pendingDelivery[ackKey] = 1;

      for (int i = 0; i < chunks.length; i++) {
        final label = "${i + 1}-${chunks.length}-$mid-$_myID-$_targetID-${chunks[i]}";
        for (int r = 0; r <= _retryCount; r++) {
          await transport.sendOnly("$label.$_baseDomain", qtype: _sendViaAAAA ? 28 : 1);
        }
      }
      setState(() {
        _messages[0]["status"] = "sent";
        _status = NodeStatus.success;
      });
      await _saveHistory();
    } catch (e) {
      setState(() => _status = NodeStatus.error);
    }
    Future.delayed(const Duration(seconds: 2), () => setState(() => _status = NodeStatus.idle));
  }

  List<String> _makeChunks(String data) {
    const int size = 30;
    final List<String> chunks = [];
    for (var i = 0; i < data.length; i += size) {
      chunks.add(data.substring(i, min(i + size, data.length)));
    }
    return chunks;
  }

  // ───────────────────────── POLLING (UPDATED) ─────────────────────────

  void _startPolling() {
    _pollTimer?.cancel();
    if (!_pollingEnabled) return;
    _pollTimer = Timer.periodic(
      Duration(seconds: _pollMin + Random().nextInt(max(1, _pollMax - _pollMin + 1))),
      (_) => _fetchBuffer(),
    );
  }

  bool _looksLikePayload(String txt) {
    if (txt.isEmpty) return false;
    if (txt == "NOP") return true;
    if (txt.startsWith("ACK2-")) return true;
    return '-'.allMatches(txt).length >= 4;
  }

  /// ✅ FIXED: do NOT split on '\x00' (it breaks AAAA padding)
  /// Only trim trailing null bytes.
  String _bytesToText(Uint8List rawBytes) {
    final s = String.fromCharCodes(rawBytes);
    // remove only trailing nulls; keep the rest intact
    // Note: Cannot use raw string for \x00, must use regular string
    int end = s.length;
    while (end > 0 && s.codeUnitAt(end - 1) == 0) {
      end--;
    }
    return s.substring(0, end).trim();
  }

  Future<void> _fetchBuffer() async {
    if (_status != NodeStatus.idle && _status != NodeStatus.polling) return;
    setState(() => _status = NodeStatus.polling);
    _gcBuffers();

    final transport = DnsTransport(serverIP: _useDirectServer ? _serverIP : null);
    bool hasMore = true;
    const int burstAttempts = 3;
    const int burstMinMs = 200;
    const int burstMaxMs = 400;

    while (hasMore) {
      Uint8List? rawBytes;
      String txt = "";
      var usedAAAA = true;
      bool looksFrame = false;

      for (int attempt = 0; attempt < burstAttempts; attempt++) {
        // 1) Try AAAA
        final pollNonce = IdUtils.generateRandomID();
        var response = await transport.sendAndReceive("v1.sync.$_myID.$pollNonce.$_baseDomain", qtype: 28);
        usedAAAA = true;

        // 2) Fallback to A only if no response
        if (response == null && _fallbackEnabled) {
          response = await transport.sendAndReceive("v1.sync.$_myID.$pollNonce.$_baseDomain", qtype: 1);
          usedAAAA = false;
        }

        if (response == null) {
          if (attempt < burstAttempts - 1) {
            await Future.delayed(Duration(milliseconds: burstMinMs + Random().nextInt(burstMaxMs - burstMinMs + 1)));
            continue;
          }
          break;
        }

        rawBytes = response;
        txt = _bytesToText(rawBytes);

        if ((txt.isEmpty || txt == "NOP") && usedAAAA && _fallbackEnabled) {
          response = await transport.sendAndReceive("v1.sync.$_myID.$pollNonce.$_baseDomain", qtype: 1);
          usedAAAA = false;
          if (response != null) {
            rawBytes = response;
            txt = _bytesToText(rawBytes);
          }
        }

        if (txt.isEmpty || txt == "NOP") {
          if (attempt < burstAttempts - 1) {
            await Future.delayed(Duration(milliseconds: burstMinMs + Random().nextInt(burstMaxMs - burstMinMs + 1)));
            continue;
          }
        }

        looksFrame = txt.startsWith("ACK2-") || '-'.allMatches(txt).length >= 4;
        if (!looksFrame && usedAAAA && _fallbackEnabled) {
          response = await transport.sendAndReceive("v1.sync.$_myID.$pollNonce.$_baseDomain", qtype: 1);
          usedAAAA = false;
          if (response != null) {
            rawBytes = response;
            txt = _bytesToText(rawBytes);
            looksFrame = txt.startsWith("ACK2-") || '-'.allMatches(txt).length >= 4;
          }
        }

        if (!looksFrame && attempt < burstAttempts - 1) {
          await Future.delayed(Duration(milliseconds: burstMinMs + Random().nextInt(burstMaxMs - burstMinMs + 1)));
          continue;
        }

        break;
      }

      if (rawBytes == null) break;

      if (txt.isEmpty || txt == "NOP") {
        hasMore = false;
        break;
      }

      // ✅ HARD GUARD: only ACK2 or full frame is allowed.
      // This prevents base32-only junk from ever reaching RX.
      if (!looksFrame) {
        if (_debugMode) print("DEBUG POLL => dropped non-frame payload: $txt");
        continue;
      }

      if (!_looksLikePayload(txt)) {
        if (_debugMode) print("DEBUG POLL => invalid payload after fallback: $txt");
        hasMore = false;
        break;
      }

      if (_debugMode) print("DEBUG POLL => $txt");

      if (txt.startsWith("ACK2-")) {
        _handleDeliveryAck(txt);
      } else {
        _handleIncomingChunk(txt);
      }

      await Future.delayed(const Duration(milliseconds: 250));
    }

    setState(() => _status = NodeStatus.idle);
  }

  void _gcBuffers() {
    final now = DateTime.now();
    _buffers.removeWhere((k, st) => now.difference(st.lastUpdatedAt) > _bufferTtl);
  }

  void _handleDeliveryAck(String txt) {
    final label = txt.split(".").first;
    final parts = label.split("-");
    if (parts.length != 3 && parts.length != 4) return;
    final sid = parts[1].toLowerCase();
    final tot = parts[2];
    final mid = parts.length == 4 ? parts[3].toLowerCase() : "";
    final key = mid.isEmpty ? "$sid:$tot" : "$sid:$tot:$mid";
    if (_pendingDelivery.containsKey(key)) {
      for (int i = 0; i < _messages.length; i++) {
        if (_messages[i]["deliveryKey"] == key) {
          setState(() => _messages[i]["status"] = "delivered");
          _saveHistory();
          break;
        }
      }
      _pendingDelivery.remove(key);
    }
  }

  // ───────────────────────── RX ─────────────────────────

  void _handleIncomingChunk(String txt) async {
    try {
      // ۱) پاکسازی کاراکترهای غیر-printable (فقط ASCII 32-126 نگه داشته شود)
      final cleanBuffer = StringBuffer();
      for (int i = 0; i < txt.length; i++) {
        final c = txt.codeUnitAt(i);
        if (c >= 32 && c <= 126) {
          cleanBuffer.writeCharCode(c);
        }
      }
      String cleanTxt = cleanBuffer.toString().trim().toLowerCase();

      // If header is rotated to the end (out-of-order DNS answers), rotate it back.
      if (!RegExp(r'^\d+-').hasMatch(cleanTxt)) {
        final headerMatch = RegExp(r'\d+-\d+-[a-z2-7]{5}-[a-z2-7]{5}-[a-z2-7]{5}-').firstMatch(cleanTxt) ??
            RegExp(r'\d+-\d+-[a-z2-7]{5}-[a-z2-7]{5}-').firstMatch(cleanTxt);
        if (headerMatch != null && headerMatch.start > 0) {
          cleanTxt = cleanTxt.substring(headerMatch.start) + cleanTxt.substring(0, headerMatch.start);
        }
      }

      // ۲) فریم باید کامل باشد: idx-tot-sid-rid-payload
      final parts = cleanTxt.split("-");
      if (parts.length != 5 && parts.length != 6) {
        if (_debugMode) print("DEBUG: Still no match for: $cleanTxt");
        return;
      }

      final idx = int.tryParse(parts[0]);
      final tot = int.tryParse(parts[1]);
      String mid = "";
      String sid = "";
      String rid = "";
      String payload = "";

      if (parts.length == 6) {
        mid = parts[2].toLowerCase();
        sid = parts[3].toLowerCase();
        rid = parts[4].toLowerCase();
        payload = parts[5].trim();
      } else {
        sid = parts[2].toLowerCase();
        rid = parts[3].toLowerCase();
        payload = parts[4].trim();
      }

      final idRe = RegExp(r'^[a-z2-7]{5}$');
      final payloadRe = RegExp(r'^[a-z2-7]+$');
      if (idx == null || tot == null) return;
      if (!idRe.hasMatch(sid) || !idRe.hasMatch(rid)) return;
      if (mid.isNotEmpty && !idRe.hasMatch(mid)) return;
      if (!payloadRe.hasMatch(payload)) return;

      if (rid != _myID.toLowerCase()) return;
      if (sid == _myID.toLowerCase()) {
        if (_debugMode) print("DEBUG: Dropped loopback frame from self: $cleanTxt");
        return;
      }

      // ✅ DROP empty payloads (prevents empty base32 / decoded bytes 0)
      if (payload.isEmpty) {
        if (_debugMode) print("DEBUG: Dropped empty payload frame: $cleanTxt");
        return;
      }

      final bufKey = mid.isEmpty ? "$sid:$rid:$tot" : "$sid:$rid:$tot:$mid";
      final st = _buffers.putIfAbsent(bufKey, () => _RxBufferState(RxAssembly(sid, tot)));
      st.lastUpdatedAt = DateTime.now();

      // add full frame (safe)
      final result = st.asm.addFrame("$idx-$tot-$sid-$rid-$payload");
      if (_debugMode) {
        if (result == AddFrameResult.added) {
          print("DEBUG: Successfully added part $idx/$tot");
        } else if (result == AddFrameResult.reset) {
          print("DEBUG: Reset buffer on part $idx/$tot (mismatch detected)");
        } else {
          print("DEBUG: Dropped invalid/duplicate part $idx/$tot");
        }
      }

      if (st.asm.isComplete) {
        if (_debugMode) print("DEBUG: Buffer $bufKey is complete. Assembling...");

        final String rawAssembled = st.asm.assemble();
        _buffers.remove(bufKey);

        // normalize base32
        String normalized = rawAssembled.toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');
        while (normalized.length % 8 != 0) {
          normalized += '=';
        }

        if (_debugMode) print("DEBUG: Final Normalized Base32: $normalized");

        try {
          final Uint8List decoded = Uint8List.fromList(base32.decode(normalized));
          if (_debugMode) print("DEBUG: Decoded bytes length: ${decoded.length}");

          final decrypted = await PeykCrypto.decrypt(decoded);
          
          // Check if decryption actually failed (returns error message)
          if (decrypted.startsWith("Error") || decrypted.startsWith("Decryption error")) {
            if (_debugMode) print("❌ Decryption failed: $decrypted");
            if (_debugMode) print("DEBUG: Raw assembled payload was: $rawAssembled");
            if (_debugMode) print("DEBUG: Normalized base32 was: $normalized");
            // Still show the error message to user for debugging
            if (!mounted) return;
            setState(() {
              _messages.insert(0, {
                "text": decrypted,
                "status": "received",
                "from": sid,
                "time": _getTime(),
              });
            });
            _saveHistory();
            return;
          }

          if (!mounted) return;
          final dedupKey = _rxDedupKey(sid, mid, tot, normalized);
          final isDup = _markSeenRx(dedupKey);
          if (!isDup) {
            if (sid != _targetID.toLowerCase()) {
              await _appendToHistoryForTarget(sid, {
                "text": decrypted,
                "status": "received",
                "from": sid,
                "time": _getTime(),
              });
              await _incrementUnread(sid);
            } else {
              setState(() {
                _messages.insert(0, {
                  "text": decrypted,
                  "status": "received",
                  "from": sid,
                  "time": _getTime(),
                });
              });
              _saveHistory();
            }
          } else if (_debugMode) {
            print("DEBUG: Dropped duplicate message $dedupKey");
          }

          // ACK2 (A + AAAA)
          final transport = DnsTransport(serverIP: _useDirectServer ? _serverIP : null);
          final ackLabel = mid.isEmpty ? "ack2-$sid-$tot" : "ack2-$sid-$tot-$mid";
          final ackNonceA = IdUtils.generateRandomID();
          final ackNonceAAAA = IdUtils.generateRandomID();
          await transport.sendOnly("$ackLabel.$ackNonceA.$_baseDomain", qtype: 1);
          await transport.sendOnly("$ackLabel.$ackNonceAAAA.$_baseDomain", qtype: 28);
        } catch (e) {
          if (_debugMode) print("❌ Decryption/Base32 Error: $e");
        }
      }
    } catch (e) {
      if (_debugMode) print("❌ Processing Error: $e");
    }
  }

  String _getTime() => "${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}";

  String _hashText(String input) {
    int hash = 0x811c9dc5;
    for (int i = 0; i < input.length; i++) {
      hash ^= input.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _rxDedupKey(String sid, String mid, int tot, String normalized) {
    if (mid.isNotEmpty) {
      return "$sid:$mid:$tot";
    }
    return "$sid:$tot:${_hashText(normalized)}";
  }

  bool _markSeenRx(String key) {
    final now = DateTime.now();
    _recentRx.removeWhere((_, ts) => now.difference(ts) > _rxDedupTtl);
    if (_recentRx.containsKey(key)) {
      return true;
    }
    _recentRx[key] = now;
    return false;
  }

  String _displayNameForId(String id) {
    final key = id.toLowerCase();
    return _contactNames[key] ?? id;
  }

  Future<void> _copyToClipboard(String text) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Copied to clipboard"), duration: Duration(milliseconds: 900)),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final clip = data?.text ?? '';
    if (clip.isEmpty) return;
    final current = _controller.text;
    _controller.text = current + clip;
    _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
  }

  Future<void> _clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey());
    if (!mounted) return;
    setState(() => _messages.clear());
  }

  Future<void> _confirmClearHistory() async {
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF111B21),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: _accent.withOpacity(0.3))),
        title: const Text("CLEAR CHAT", style: TextStyle(fontSize: 12, letterSpacing: 2, fontWeight: FontWeight.bold, color: _accent)),
        content: const Text("This will remove local history for this chat.", style: TextStyle(color: _textDim, fontSize: 12)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("CANCEL", style: TextStyle(color: Colors.white30))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _accent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            onPressed: () async {
              await _clearHistory();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text("CLEAR", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // ───────────────────────── UI (بدون تغییر گرافیکی) ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final title = widget.displayName?.isNotEmpty == true ? widget.displayName! : _targetID;
    final subtitle = widget.displayName?.isNotEmpty == true ? _targetID : "";
    final initial = title.isNotEmpty ? title[0].toUpperCase() : "?";
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(colors: [_accent, _accentAlt]),
                boxShadow: [
                  BoxShadow(color: _accent.withOpacity(0.3), blurRadius: 8),
                ],
              ),
              child: Center(
                child: Text(initial, style: const TextStyle(color: Color(0xFF001018), fontSize: 12)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: const TextStyle(letterSpacing: 1, fontSize: 12, fontWeight: FontWeight.bold)),
                  if (subtitle.isNotEmpty)
                    Text(subtitle, style: const TextStyle(color: _textDim, fontSize: 9)),
                ],
              ),
            ),
          ],
        ),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0B141A), Color(0xFF111B21)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        actions: [IconButton(icon: const Icon(Icons.settings, size: 20), onPressed: _showSettings)],
      ),
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF0B141A),
                  Color(0xFF0E1A20),
                  Color(0xFF111B21),
                ],
              ),
            ),
          ),
          Positioned(
            top: -60,
            right: -40,
            child: Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _accent.withOpacity(0.06),
              ),
            ),
          ),
          Positioned(
            bottom: -80,
            left: -40,
            child: Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _accentAlt.withOpacity(0.05),
              ),
            ),
          ),
          Column(
            children: [
              _buildStatusLine(),
              Expanded(child: _buildChatList()),
              _buildInputArea(),
            ],
          ),
          Positioned(
            right: 16,
            bottom: 96,
            child: AnimatedOpacity(
              opacity: _showJumpToBottom ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: IgnorePointer(
                ignoring: !_showJumpToBottom,
                child: GestureDetector(
                  onTap: () {
                    if (_chatScrollCtrl.hasClients) {
                      _chatScrollCtrl.animateTo(
                        0,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                      );
                    }
                  },
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        colors: [_accent, _accentAlt],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _accent.withOpacity(0.3),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.arrow_downward, size: 18, color: Color(0xFF001018)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusLine() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF111B21),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF202C33)),
        ),
        child: Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: _status == NodeStatus.error ? Colors.redAccent : _accent,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                "SYS: ${_status.name.toUpperCase()} | NODE: $_myID",
                style: const TextStyle(color: Color(0xFF00A884), fontSize: 9, letterSpacing: 1),
              ),
            ),
            if (!_pollingEnabled)
              IconButton(
                icon: const Icon(Icons.sync, size: 16, color: _accent),
                tooltip: "Manual Sync",
                onPressed: _fetchBuffer,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatList() {
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      controller: _chatScrollCtrl,
      itemCount: _messages.length,
      itemBuilder: (context, index) => _buildMessageBubble(_messages[index]),
    );
  }

  Widget _buildMessageBubble(Map<String, dynamic> msg) {
    bool isRx = msg["status"] == "received";
    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isRx ? const Color(0xFF202C33) : const Color(0xFF005C4B),
        borderRadius: BorderRadius.circular(16).copyWith(
          bottomLeft: isRx ? Radius.zero : const Radius.circular(16),
          bottomRight: isRx ? const Radius.circular(16) : Radius.zero,
        ),
        border: Border.all(color: isRx ? const Color(0xFF1F2C34) : const Color(0xFF004C3F)),
      ),
      child: Column(
        crossAxisAlignment: isRx ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        children: [
          if (isRx)
            Text(
              _displayNameForId((msg["from"] ?? "").toString()),
              style: const TextStyle(color: Color(0xFF00A884), fontSize: 8, fontWeight: FontWeight.bold, letterSpacing: 1),
            ),
          SelectableText(
            msg["text"],
            style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.25),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(msg["time"], style: const TextStyle(color: _textDim, fontSize: 8)),
              const SizedBox(width: 4),
              if (msg["status"] != "received") _buildStatusIcon(msg["status"]),
            ],
          ),
        ],
      ),
    );

    return Align(
      alignment: isRx ? Alignment.centerLeft : Alignment.centerRight,
      child: GestureDetector(
        onLongPress: () => _copyToClipboard((msg["text"] ?? "").toString()),
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 220),
          builder: (context, value, child) => Opacity(
            opacity: value,
            child: Transform.translate(offset: Offset(0, (1 - value) * 6), child: child),
          ),
          child: bubble,
        ),
      ),
    );
  }

  Widget _buildStatusIcon(String status) {
    switch (status) {
      case "sending":
        return const Icon(Icons.check, size: 14, color: Color(0xFF8696A0));
      case "sent":
        return const Icon(Icons.check, size: 14, color: Color(0xFF8696A0));
      case "delivered":
        return const Icon(Icons.done_all, size: 14, color: _accent);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 28),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF111B21),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF202C33)),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                style: const TextStyle(fontSize: 14, color: Colors.white),
                decoration: InputDecoration(
                  hintText: _targetID.isEmpty ? "Set Target in Settings" : "Message to $_targetID...",
                  hintStyle: const TextStyle(color: _textDim),
                  filled: true,
                  fillColor: const Color(0xFF202C33),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.paste, color: Color(0xFF00A884), size: 18),
              tooltip: "Paste",
              onPressed: _pasteFromClipboard,
            ),
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF00A884),
              ),
              child: IconButton(
                icon: const Icon(Icons.send, color: Colors.white, size: 20),
                onPressed: _sendMessage,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final domainCtrl = TextEditingController(text: _baseDomain);
    final targetCtrl = TextEditingController(text: _targetID);
    final ipCtrl = TextEditingController(text: _serverIP);
    final pollMinCtrl = TextEditingController(text: _pollMin.toString());
    final pollMaxCtrl = TextEditingController(text: _pollMax.toString());
    final retryCtrl = TextEditingController(text: _retryCount.toString());
    bool advancedOpen = true;

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setL) => AlertDialog(
          backgroundColor: const Color(0xFF111B21),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: _accent.withOpacity(0.3))),
          title: const Text("NODE CONFIGURATION", style: TextStyle(fontSize: 12, letterSpacing: 2, fontWeight: FontWeight.bold, color: _accent)),
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
                      border: Border.all(color: _accent.withOpacity(_glowAnim.value)),
                      boxShadow: [BoxShadow(color: _accent.withOpacity(_glowAnim.value * 0.3), blurRadius: 15, spreadRadius: 1)],
                    ),
                    child: Column(
                      children: [
                        const Text("YOUR UNIQUE ADDRESS", style: TextStyle(fontSize: 8, color: Colors.white38)),
                        const SizedBox(height: 8),
                        SelectableText(_myID, style: const TextStyle(fontSize: 22, letterSpacing: 4, fontFamily: 'monospace', color: Colors.white)),
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
                    Text("Arash, MEL - Jan2026", style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.white54)),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF111B21),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF202C33)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("CONNECTION", style: TextStyle(fontSize: 10, letterSpacing: 2, color: _textDim)),
                      const SizedBox(height: 6),
                      _buildSettingField(targetCtrl, "Target Node ID", Icons.person_pin, "abcde", enabled: false),
                      _buildSettingField(ipCtrl, "Relay Server IP", Icons.lan, "1.2.3.4", enabled: _useDirectServer),
                      _buildSettingField(domainCtrl, "Base Domain", Icons.dns, "p99.peyk-d.ir"),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text("Use Direct Server IP", style: TextStyle(fontSize: 12, color: Colors.white70)),
                        value: _useDirectServer,
                        activeColor: _accent,
                        onChanged: (v) => setL(() => _useDirectServer = v),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFF111B21),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF202C33)),
                  ),
                  child: ExpansionTile(
                    initiallyExpanded: advancedOpen,
                    onExpansionChanged: (v) => setL(() => advancedOpen = v),
                    iconColor: _accent,
                    collapsedIconColor: _accent,
                    title: const Text("ADVANCED", style: TextStyle(fontSize: 10, letterSpacing: 2, color: _textDim)),
                    childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text("Send via AAAA", style: TextStyle(fontSize: 12, color: Colors.white70)),
                        value: _sendViaAAAA,
                        activeColor: _accent,
                        onChanged: (v) => setL(() => _sendViaAAAA = v),
                      ),
                      Row(children: [
                        Expanded(child: _buildSettingField(pollMinCtrl, "Min Poll", Icons.timer_outlined, "20", isNum: true)),
                        const SizedBox(width: 10),
                        Expanded(child: _buildSettingField(pollMaxCtrl, "Max Poll", Icons.timer, "40", isNum: true)),
                      ]),
                      _buildSettingField(retryCtrl, "Retries", Icons.repeat, "1", isNum: true),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text("Active Polling", style: TextStyle(fontSize: 12, color: Colors.white70)),
                        value: _pollingEnabled,
                        activeColor: _accent,
                        onChanged: (v) => setL(() => _pollingEnabled = v),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text("A Fallback on No Response", style: TextStyle(fontSize: 12, color: Colors.white70)),
                        value: _fallbackEnabled,
                        activeColor: _accent,
                        onChanged: (v) => setL(() => _fallbackEnabled = v),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text("Debug Mode", style: TextStyle(fontSize: 12, color: Colors.white70)),
                        value: _debugMode,
                        activeColor: _accentAlt,
                        onChanged: (v) => setL(() => _debugMode = v),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: _confirmClearHistory, child: const Text("CLEAR CHAT", style: TextStyle(color: _accentAlt))),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("DISCARD", style: TextStyle(color: Colors.white30))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: _accent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              onPressed: () async {
                await prefs.setString('target_id', targetCtrl.text.trim());
                await prefs.setString('server_ip', ipCtrl.text.trim());
                await prefs.setString('base_domain', domainCtrl.text.trim());
                await prefs.setInt('poll_min', int.tryParse(pollMinCtrl.text) ?? 20);
                await prefs.setInt('poll_max', int.tryParse(pollMaxCtrl.text) ?? 40);
                await prefs.setInt('retry_count', int.tryParse(retryCtrl.text) ?? 1);
                await prefs.setBool('polling_enabled', _pollingEnabled);
                await prefs.setBool('debug_mode', _debugMode);
                await prefs.setBool('fallback_enabled', _fallbackEnabled);
                await prefs.setBool('use_direct_server', _useDirectServer);
                await prefs.setBool('send_via_aaaa', _sendViaAAAA);
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

  Widget _buildSettingField(TextEditingController ctrl, String label, IconData icon, String hint, {bool isNum = false, bool enabled = true}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextField(
        enabled: enabled,
        controller: ctrl,
        keyboardType: isNum ? TextInputType.number : TextInputType.text,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon, size: 18, color: _accent),
          labelStyle: const TextStyle(color: _textDim, fontSize: 12),
          filled: true,
          fillColor: const Color(0xFF202C33),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _glowCtrl.dispose();
    _controller.dispose();
    _chatScrollCtrl.dispose();
    super.dispose();
  }
}
