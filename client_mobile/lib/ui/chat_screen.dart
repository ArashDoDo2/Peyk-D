import 'dart:typed_data';
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:base32/base32.dart';

// Core layers
import '../core/protocol.dart';
import '../core/crypto.dart';
import '../core/notifications.dart';
import '../core/rx_assembly.dart';
import '../core/transport.dart';
import '../core/decode_worker.dart';
import '../utils/id.dart';

enum NodeStatus { idle, polling, sending, success, error }

class _RxBufferState {
  final RxAssembly asm;
  DateTime createdAt;
  DateTime lastUpdatedAt;
  int lastPercent;

  _RxBufferState(this.asm)
      : createdAt = DateTime.now(),
        lastUpdatedAt = DateTime.now(),
        lastPercent = 0;
}

class ChatScreen extends StatefulWidget {
  final String targetId;
  final String? displayName;

  const ChatScreen({super.key, required this.targetId, this.displayName});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final List<Map<String, dynamic>> _messages = [];
  final Map<String, _RxBufferState> _buffers = {};
  final Map<String, int> _pendingDelivery = {};
  final Map<String, DateTime> _pendingLastSent = {};
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
  bool _directTcp = false;
  bool _sendViaAAAA = false;
  String _locationMode = "iran";
  int _pollMin = 20;
  int _pollMax = 40;
  int _retryCount = 3;
  String _debugInfo = "";
  int _txPercent = 0;
  bool _txActive = false;
  DateTime _lastTxUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  bool _txInFlight = false;
  int _txResetToken = 0;

  Timer? _pollTimer;

  static const Duration _bufferTtl = Duration(seconds: 90);
  static const int _historyMax = 200;
  static const Duration _rxDedupTtl = Duration(minutes: 10);
  static const Duration _resendMinInterval = Duration(seconds: 20);
  static const Duration _resendMaxInterval = Duration(minutes: 5);
  static const Duration _sendChunkDelay = Duration(milliseconds: 50);
  static const Duration _pendingDeliveryTtl = Duration(hours: 12);
  static const bool _enableResend = false;
  static const Color _accent = Color(0xFF00A884);
  static const Color _accentAlt = Color(0xFF25D366);
  static const Color _panel = Color(0xFF111B21);
  static const Color _panelAlt = Color(0xFF0B141A);
  static const Color _textDim = Color(0xFF8696A0);
  static const int _maxMessageChars = 280;
  static const int _dnsTimeoutMsDefault = 1800;
  static const int _dnsTimeoutMsDirect = 2000;

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _loadSettings();
    _chatScrollCtrl.addListener(_handleChatScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _inputFocus.requestFocus();
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    });
  }

  void _setupAnimations() {
  }

  void _setDebugInfo(String info) {
    if (!_debugMode) return;
    if (_debugInfo == info) {
      return;
    }
    setState(() => _debugInfo = info);
  }

  String _pollDebugLabel() {
    final pct = _currentRxPercent();
    if (pct == null) {
      return "RX: wait";
    }
    return "RX: ${pct}%";
  }

  void _setTxPercent(int pct) {
    final now = DateTime.now();
    if (pct == _txPercent && now.difference(_lastTxUiUpdate) < const Duration(milliseconds: 250)) {
      return;
    }
    _lastTxUiUpdate = now;
    setState(() => _txPercent = pct.clamp(0, 100));
  }

  Map<String, dynamic>? _findMessageByTimestamp(int ts) {
    if (ts <= 0) return null;
    for (final msg in _messages) {
      if (_messageTimestampMs(msg) == ts) {
        return msg;
      }
    }
    return null;
  }

  Map<String, dynamic>? _findMessageByMid(String mid) {
    final needle = mid.toLowerCase();
    for (final msg in _messages) {
      final msgMid = (msg["mid"] ?? "").toString().toLowerCase();
      if (msgMid.isNotEmpty && msgMid == needle) {
        return msg;
      }
    }
    return null;
  }

  void _resetTxStatus() {
    final token = ++_txResetToken;
    _txInFlight = false;
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      if (token != _txResetToken) return;
      setState(() {
        _status = NodeStatus.idle;
        _txActive = false;
        _txPercent = 0;
      });
    });
  }

  int? _currentRxPercent() {
    if (_buffers.isEmpty) return null;
    _RxBufferState? latest;
    for (final entry in _buffers.entries) {
      final key = entry.key;
      final st = entry.value;
      final parts = key.split(":");
      if (parts.length >= 4) {
        final sid = parts[0];
        if (sid != _targetID.toLowerCase()) {
          continue;
        }
      }
      if (latest == null || st.lastUpdatedAt.isAfter(latest.lastUpdatedAt)) {
        latest = st;
      }
    }
    if (latest == null) {
      for (final st in _buffers.values) {
        if (latest == null || st.lastUpdatedAt.isAfter(latest.lastUpdatedAt)) {
          latest = st;
        }
      }
    }
    if (latest == null) return null;
    if (latest.lastPercent > 0) return latest.lastPercent.clamp(0, 100);
    final total = latest.asm.total;
    if (total <= 0) return null;
    final received = latest.asm.receivedCount;
    final pct = ((received * 100) / total).floor();
    return pct.clamp(0, 100);
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
    final savedLocation = prefs.getString('location_mode') ?? "";
    String nextLocation = savedLocation;
    final defaultServerIP = PeykProtocol.defaultServerIP;
    if (nextLocation.isEmpty) {
      final savedDirect = prefs.getBool('use_direct_server') ?? false;
      final savedDirectTcp = prefs.getBool('direct_tcp') ?? false;
      final savedIP = prefs.getString('server_ip') ?? "";
      if (savedDirect && defaultServerIP.isNotEmpty && savedIP == defaultServerIP) {
        nextLocation = savedDirectTcp ? "other_direct" : "other";
      } else {
        nextLocation = "iran";
      }
    }

    setState(() {
      _myID = prefs.getString('my_id') ?? IdUtils.generateRandomID();
      _targetID = widget.targetId;
      _serverIP = prefs.getString('server_ip') ?? PeykProtocol.defaultServerIP;
      _baseDomain = prefs.getString('base_domain') ?? PeykProtocol.baseDomain;
      _pollMin = prefs.getInt('poll_min') ?? 3;
      _pollMax = prefs.getInt('poll_max') ?? 10;
      _retryCount = prefs.getInt('retry_count') ?? 3;
      _pollingEnabled = prefs.getBool('polling_enabled') ?? true;
      _debugMode = prefs.getBool('debug_mode') ?? false;
      _fallbackEnabled = prefs.getBool('fallback_enabled') ?? true;
      _useDirectServer = prefs.getBool('use_direct_server') ?? false;
      _directTcp = prefs.getBool('direct_tcp') ?? false;
      _sendViaAAAA = prefs.getBool('send_via_aaaa') ?? false;
      _locationMode = nextLocation;
      _contactNames = names;

      if (_locationMode == "iran") {
        _useDirectServer = false;
        _directTcp = false;
        _sendViaAAAA = true;
        _fallbackEnabled = true;
        _retryCount = 3;
      } else if (_locationMode == "other") {
        _useDirectServer = true;
        _directTcp = false;
        _serverIP = defaultServerIP;
        _sendViaAAAA = true;
        _fallbackEnabled = true;
        _retryCount = 3;
      } else if (_locationMode == "other_direct") {
        _useDirectServer = true;
        _directTcp = true;
        _serverIP = defaultServerIP;
        _sendViaAAAA = true;
        _fallbackEnabled = true;
        _retryCount = 3;
      }

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
        _rebuildPendingDelivery();
        _cleanupStalePending(persistHistory: true);
      }
    } catch (_) {
      // ignore bad history
    }
  }

  int _dnsTimeoutMs() {
    if (_useDirectServer) {
      return _dnsTimeoutMsDirect;
    }
    return _dnsTimeoutMsDefault;
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
    if (_txInFlight) {
      if (_debugMode) print("DEBUG: TX already in flight, ignoring new message");
      return;
    }
    _txInFlight = true;
    _txResetToken++;
    _controller.clear();

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final msg = <String, dynamic>{
      "text": text,
      "status": "sending",
      "time": _getTime(),
      "to": _targetID,
      "ts": nowMs,
    };
    setState(() {
      _messages.insert(0, msg);
      _status = NodeStatus.sending;
      _txActive = true;
      _txPercent = 0;
    });

    try {
      await _saveHistory();
      _setDebugInfo("TX: encrypting...");
      final encrypted = await PeykCrypto.encrypt(text);
      final b32 = base32.encode(encrypted).toLowerCase().replaceAll('=', '');
      final chunks = _makeChunks(b32);
      _setDebugInfo("TX: sending ${chunks.length} chunks");
      final transport = DnsTransport(serverIP: _useDirectServer ? _serverIP : null, useTcp: _directTcp);
      final mid = IdUtils.generateRandomID();
      final timeoutMs = _dnsTimeoutMs();

      msg["mid"] = mid;
      msg["chunks"] = chunks;

      bool allAcked = true;
      for (int i = 0; i < chunks.length; i++) {
        final label = "${i + 1}-${chunks.length}-$mid-$_myID-$_targetID-${chunks[i]}";
        if (chunks.length > 6) {
          await Future.delayed(_sendChunkDelay);
        }
        bool acked = false;
        for (int r = 0; r <= _retryCount; r++) {
          Uint8List? response;
          if (_sendViaAAAA) {
            response = await transport.sendAndReceive("$label.$_baseDomain", qtype: 28, timeoutMs: timeoutMs);
            if (response == null && _fallbackEnabled) {
              response = await transport.sendAndReceive("$label.$_baseDomain", qtype: 1, timeoutMs: timeoutMs);
            }
          } else {
            response = await transport.sendAndReceive("$label.$_baseDomain", qtype: 1, timeoutMs: timeoutMs);
          }
          if (response != null) {
            acked = true;
            break;
          }
          if (r < _retryCount) {
            await Future.delayed(const Duration(milliseconds: 120));
          }
        }
        if (!acked) {
          allAcked = false;
          break;
        }
        final pct = (((i + 1) * 100) / chunks.length).floor();
        _setTxPercent(pct);
      }

      if (allAcked) {
        final ackKey = "${_myID.toLowerCase()}:${chunks.length}:$mid";
        msg["deliveryKey"] = ackKey;
        _pendingDelivery[ackKey] = 1;
        _pendingLastSent[ackKey] = DateTime.now();
        _setDebugInfo("TX: sent ${chunks.length}/${chunks.length}");
        setState(() {
          msg["status"] = "sent";
          _status = NodeStatus.success;
          _txPercent = 100;
        });
        await _saveHistory();
      } else {
        _setDebugInfo("TX: server ack failed");
        setState(() {
          msg["status"] = "error";
          _status = NodeStatus.error;
        });
        await _saveHistory();
      }
    } catch (e) {
      _setDebugInfo("TX: error");
      setState(() {
        msg["status"] = "error";
        _status = NodeStatus.error;
        _txActive = false;
      });
      await _saveHistory();
    } finally {
      _resetTxStatus();
    }
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
    if (_debugMode) {
      _setDebugInfo(_pollDebugLabel());
    }
    _gcBuffers();

    final transport = DnsTransport(serverIP: _useDirectServer ? _serverIP : null, useTcp: _directTcp);
    bool hasMore = true;
    const int burstAttempts = 3;
    const int burstMinMs = 200;
    const int burstMaxMs = 400;
    const int maxLoops = 5;
    const int burstMaxLoops = 40;
    const Duration maxBudget = Duration(seconds: 5);
    const Duration burstBudget = Duration(seconds: 12);
    final startAt = DateTime.now();
    var lastProgressAt = startAt;
    int loops = 0;
    bool burstMode = false;
    int framesSeen = 0;
    final timeoutMs = _dnsTimeoutMs();

    while (hasMore) {
      if (!_pollingEnabled) break;
      final loopLimit = burstMode ? burstMaxLoops : maxLoops;
      final budgetLimit = burstMode ? burstBudget : maxBudget;
      final budgetStart = burstMode ? lastProgressAt : startAt;
      if (loops >= loopLimit || DateTime.now().difference(budgetStart) > budgetLimit) {
        break;
      }
      loops++;
      if (_debugMode) {
        _setDebugInfo(_pollDebugLabel());
      }

      Uint8List? rawBytes;
      String txt = "";
      var usedAAAA = true;
      bool looksFrame = false;

      for (int attempt = 0; attempt < burstAttempts; attempt++) {
        // 1) Try AAAA
        final pollNonce = IdUtils.generateRandomID();
        var response = await transport.sendAndReceive(
          "v1.sync.$_myID.$pollNonce.$_baseDomain",
          qtype: 28,
          timeoutMs: timeoutMs,
        );
        usedAAAA = true;

        // 2) Fallback to A only if no response
        if (response == null && _fallbackEnabled) {
          response = await transport.sendAndReceive(
            "v1.sync.$_myID.$pollNonce.$_baseDomain",
            qtype: 1,
            timeoutMs: timeoutMs,
          );
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
          response = await transport.sendAndReceive(
            "v1.sync.$_myID.$pollNonce.$_baseDomain",
            qtype: 1,
            timeoutMs: timeoutMs,
          );
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
          response = await transport.sendAndReceive(
            "v1.sync.$_myID.$pollNonce.$_baseDomain",
            qtype: 1,
            timeoutMs: timeoutMs,
          );
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
      if (looksFrame) {
        framesSeen++;
      }
      if (!burstMode && framesSeen >= 2) {
        burstMode = true;
      }
      lastProgressAt = DateTime.now();

      if (!looksFrame) {
        await Future.delayed(burstMode ? const Duration(milliseconds: 80) : const Duration(milliseconds: 250));
      }
    }

    await _resendPending();

    setState(() => _status = NodeStatus.idle);
    if (_debugMode && _buffers.isEmpty) {
      _setDebugInfo("SYS: idle");
    }
  }

  void _gcBuffers() {
    final now = DateTime.now();
    _buffers.removeWhere((k, st) => now.difference(st.lastUpdatedAt) > _bufferTtl);
  }

  void _handleDeliveryAck(String txt) {
    final label = txt.split(".").first;
    final parts = label.split("-");
    if (parts.length != 4) return;
    final sid = parts[1].toLowerCase();
    final tot = parts[2];
    final mid = parts[3].toLowerCase();
    final key = "$sid:$tot:$mid";
    for (int i = 0; i < _messages.length; i++) {
      if (_messages[i]["deliveryKey"] == key) {
        setState(() => _messages[i]["status"] = "delivered");
        _saveHistory();
        break;
      }
    }
    _pendingDelivery.remove(key);
    _pendingLastSent.remove(key);
  }

  void _rebuildPendingDelivery() {
    _pendingDelivery.clear();
    _pendingLastSent.clear();
    final now = DateTime.now();
    for (final msg in _messages) {
      if (msg["status"] == "sent" && msg["deliveryKey"] != null) {
        final tsMs = _messageTimestampMs(msg);
        if (tsMs <= 0) {
          continue;
        }
        final age = now.difference(DateTime.fromMillisecondsSinceEpoch(tsMs));
        if (age > _pendingDeliveryTtl) {
          continue;
        }
        final key = msg["deliveryKey"].toString();
        _pendingDelivery[key] = 1;
        _pendingLastSent[key] = DateTime.fromMillisecondsSinceEpoch(0);
      }
    }
  }

  int _messageTimestampMs(Map<String, dynamic> msg) {
    final ts = msg["ts"];
    if (ts is int) return ts;
    if (ts is num) return ts.toInt();
    if (ts is String) return int.tryParse(ts) ?? 0;
    return 0;
  }

  void _cleanupStalePending({bool persistHistory = false}) {
    if (_pendingDelivery.isEmpty) return;
    final now = DateTime.now();
    final staleKeys = <String>[];

    for (final key in _pendingDelivery.keys) {
      Map<String, dynamic>? msg;
      for (final m in _messages) {
        if (m["deliveryKey"] == key) {
          msg = m;
          break;
        }
      }
      if (msg == null) {
        staleKeys.add(key);
        continue;
      }
      final tsMs = _messageTimestampMs(msg);
      if (tsMs <= 0) {
        staleKeys.add(key);
        continue;
      }
      final age = now.difference(DateTime.fromMillisecondsSinceEpoch(tsMs));
      if (age > _pendingDeliveryTtl) {
        staleKeys.add(key);
      }
    }

    if (staleKeys.isEmpty) return;
    for (final key in staleKeys) {
      _pendingDelivery.remove(key);
      _pendingLastSent.remove(key);
    }
    if (persistHistory) {
      _saveHistory();
    }
    if (_debugMode) _setDebugInfo("TX: cleared ${staleKeys.length} stale");
  }

  Duration _resendBackoff(int attempt) {
    if (attempt <= 1) return _resendMinInterval;
    var multiplier = 1 << (attempt - 1);
    if (multiplier < 1) multiplier = 1;
    final wait = _resendMinInterval * multiplier;
    return wait > _resendMaxInterval ? _resendMaxInterval : wait;
  }

  Future<void> _resendPending() async {
    if (!_enableResend) return;
    _cleanupStalePending();
    if (_pendingDelivery.isEmpty || !_pollingEnabled) return;
    final now = DateTime.now();
    final transport = DnsTransport(serverIP: _useDirectServer ? _serverIP : null, useTcp: _directTcp);

    for (final entry in _pendingDelivery.entries) {
      final key = entry.key;
      final attempt = entry.value;
      final lastSent = _pendingLastSent[key] ?? DateTime.fromMillisecondsSinceEpoch(0);
      if (now.difference(lastSent) < _resendBackoff(attempt)) {
        continue;
      }

      Map<String, dynamic>? msg;
      for (final m in _messages) {
        if (m["deliveryKey"] == key) {
          msg = m;
          break;
        }
      }
      if (msg == null) continue;
      if (msg["status"] == "delivered") {
        _pendingDelivery.remove(key);
        _pendingLastSent.remove(key);
        continue;
      }

      final mid = (msg["mid"] ?? "").toString();
      final to = (msg["to"] ?? _targetID).toString();
      final chunks = msg["chunks"];
      if (mid.isEmpty || to.isEmpty || chunks is! List) {
        continue;
      }

      final total = chunks.length;
      for (int i = 0; i < total; i++) {
        final chunk = chunks[i].toString();
        if (chunk.isEmpty) continue;
        final label = "${i + 1}-$total-$mid-$_myID-$to-$chunk";
        await transport.sendOnly("$label.$_baseDomain", qtype: _sendViaAAAA ? 28 : 1);
      }

      _pendingDelivery[key] = attempt + 1;
      _pendingLastSent[key] = now;
      if (_debugMode) _setDebugInfo("TX: resend $key");
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
        final headerMatch = RegExp(r'\d+-\d+-[a-z2-7]{5}-[a-z2-7]{5}-[a-z2-7]{5}-').firstMatch(cleanTxt);
        if (headerMatch != null && headerMatch.start > 0) {
          cleanTxt = cleanTxt.substring(headerMatch.start) + cleanTxt.substring(0, headerMatch.start);
        }
      }

      // ۲) فریم باید کامل باشد: idx-tot-sid-rid-payload
      final parts = cleanTxt.split("-");
      if (parts.length != 6) {
        if (_debugMode) print("DEBUG: Still no match for: $cleanTxt");
        return;
      }

      final idx = int.tryParse(parts[0]);
      final tot = int.tryParse(parts[1]);
      final mid = parts[2].toLowerCase();
      final sid = parts[3].toLowerCase();
      final rid = parts[4].toLowerCase();
      final payload = parts[5].trim();

      final idRe = RegExp(r'^[a-z2-7]{5}$');
      final payloadRe = RegExp(r'^[a-z2-7]+$');
      if (idx == null || tot == null) return;
      if (!idRe.hasMatch(sid) || !idRe.hasMatch(rid)) return;
      if (!idRe.hasMatch(mid)) return;
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

        final dedupKey = _rxDedupKey(sid, mid, tot);
        if (_isRecentlySeenRx(dedupKey)) {
          if (_debugMode) print("DEBUG: Dropped late chunk for delivered $dedupKey");
          _setDebugInfo("RX: late $idx/$tot");
          await _sendAck2(sid, tot, mid);
          return;
        }

        final bufKey = "$sid:$rid:$tot:$mid";
      final st = _buffers.putIfAbsent(bufKey, () => _RxBufferState(RxAssembly(sid, tot)));
      st.lastUpdatedAt = DateTime.now();

      // add full frame (safe)
      final result = st.asm.addFrame("$idx-$tot-$sid-$rid-$payload");
      final totalParts = st.asm.total;
      if (totalParts > 0) {
        final received = st.asm.receivedCount;
        final pct = ((received * 100) / totalParts).floor();
        if (pct > st.lastPercent) {
          st.lastPercent = pct.clamp(0, 100);
        }
      }
      if (_debugMode) {
        if (result == AddFrameResult.added) {
          print("DEBUG: Successfully added part $idx/$tot");
          _setDebugInfo("RX: chunk $idx/$tot");
        } else if (result == AddFrameResult.reset) {
          print("DEBUG: Reset buffer on part $idx/$tot (mismatch detected)");
          _setDebugInfo("RX: reset at $idx/$tot");
        } else {
          print("DEBUG: Dropped invalid/duplicate part $idx/$tot");
          _setDebugInfo("RX: dropped $idx/$tot");
        }
      }

      if (st.asm.isComplete) {
        if (_debugMode) print("DEBUG: Buffer $bufKey is complete. Assembling...");
        _setDebugInfo("RX: assembling...");

        final String rawAssembled = st.asm.assemble();
        _buffers.remove(bufKey);

        try {
          _setDebugInfo("RX: decoding...");
          final result = await compute(decodeAndDecrypt, {
            "raw": rawAssembled,
            "debug": _debugMode,
          });
          final decrypted = (result["decrypted"] as String?) ?? "Decryption error: empty result";
          final decodedLen = (result["decodedLen"] as int?) ?? 0;
          if (_debugMode) {
            final normalized = (result["normalized"] as String?) ?? "";
            if (normalized.isNotEmpty) {
              print("DEBUG: Final Normalized Base32: $normalized");
            }
            print("DEBUG: Decoded bytes length: $decodedLen");
          }
          
          // Check if decryption actually failed (returns error message)
          if (decrypted.startsWith("Error") || decrypted.startsWith("Decryption error")) {
            final displayError = decrypted.startsWith("Decryption error")
                ? "Decryption error (check passphrase)"
                : decrypted;
            if (_debugMode) print("❌ Decryption failed: $decrypted");
            if (_debugMode) print("DEBUG: Raw assembled payload was: $rawAssembled");
            final normalized = (result["normalized"] as String?) ?? "";
            if (_debugMode && normalized.isNotEmpty) {
              print("DEBUG: Normalized base32 was: $normalized");
            }
            // Still show the error message to user for debugging
            if (!mounted) return;
            setState(() {
              _messages.insert(0, {
                "text": displayError,
                "status": "received",
                "from": sid,
                "time": _getTime(),
                "ts": DateTime.now().millisecondsSinceEpoch,
              });
            });
            _saveHistory();
            return;
          }

          if (!mounted) return;
          final dedupKey = _rxDedupKey(sid, mid, tot);
          final isDup = _markSeenRx(dedupKey);
          if (!isDup) {
            final nowMs = DateTime.now().millisecondsSinceEpoch;
            if (sid != _targetID.toLowerCase()) {
              await _appendToHistoryForTarget(sid, {
                "text": decrypted,
                "status": "received",
                "from": sid,
                "time": _getTime(),
                "ts": nowMs,
              });
              await _incrementUnread(sid);
              await NotificationService.showIncomingMessage(_displayNameForId(sid), decrypted);
            } else {
              setState(() {
                _messages.insert(0, {
                  "text": decrypted,
                  "status": "received",
                  "from": sid,
                  "time": _getTime(),
                  "ts": nowMs,
                });
              });
              _saveHistory();
              await NotificationService.showIncomingMessage(_displayNameForId(sid), decrypted);
            }
            _setDebugInfo("RX: message ready");
          } else if (_debugMode) {
            print("DEBUG: Dropped duplicate message $dedupKey");
          }

          await _sendAck2(sid, tot, mid);
          _setDebugInfo("RX: ACK2 sent");
        } catch (e) {
          if (_debugMode) print("❌ Decryption/Base32 Error: $e");
          _setDebugInfo("RX: decode error");
        }
      }
    } catch (e) {
      if (_debugMode) print("❌ Processing Error: $e");
    }
  }

  Future<void> _sendAck2(String sid, int tot, String mid) async {
    final transport = DnsTransport(serverIP: _useDirectServer ? _serverIP : null, useTcp: _directTcp);
    final ackLabel = "ack2-$sid-$tot-$mid";
    final ackNonceA = IdUtils.generateRandomID();
    final ackNonceAAAA = IdUtils.generateRandomID();
    await transport.sendOnly("$ackLabel.$ackNonceA.$_baseDomain", qtype: 1);
    await transport.sendOnly("$ackLabel.$ackNonceAAAA.$_baseDomain", qtype: 28);
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

    String _rxDedupKey(String sid, String mid, int tot) {
      return "$sid:$mid:$tot";
    }

    bool _isRecentlySeenRx(String key) {
      final now = DateTime.now();
      _recentRx.removeWhere((_, ts) => now.difference(ts) > _rxDedupTtl);
      return _recentRx.containsKey(key);
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

  bool _isRtlText(String text) {
    return RegExp(r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF]').hasMatch(text);
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
    final combined = current + clip;
    if (combined.length > _maxMessageChars) {
      _controller.text = combined.substring(0, _maxMessageChars);
    } else {
      _controller.text = combined;
    }
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
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep, size: 20),
            tooltip: "Clear Chat",
            onPressed: _confirmClearHistory,
          ),
        ],
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
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFF00A884), fontSize: 9, letterSpacing: 1),
              ),
            ),
            if (_txActive)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(
                  "TX ${_txPercent}%",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _textDim, fontSize: 9),
                ),
              ),
            if (_debugMode)
              Flexible(
                child: Text(
                  _debugInfo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _textDim, fontSize: 9),
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
      itemBuilder: (context, index) => _buildMessageBubble(_messages[index], index),
    );
  }

  Widget _buildMessageBubble(Map<String, dynamic> msg, int index) {
    bool isRx = msg["status"] == "received";
    final textValue = (msg["text"] ?? "").toString();
    final isRtlMsg = _isRtlText(textValue);
    final msgTs = _messageTimestampMs(msg);
    final msgMid = (msg["mid"] ?? "").toString();
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
        crossAxisAlignment: isRx
            ? (isRtlMsg ? CrossAxisAlignment.end : CrossAxisAlignment.start)
            : CrossAxisAlignment.end,
        children: [
          if (isRx)
            Align(
              alignment: isRtlMsg ? Alignment.centerRight : Alignment.centerLeft,
              child: Text(
                _displayNameForId((msg["from"] ?? "").toString()),
                textDirection: isRtlMsg ? TextDirection.rtl : TextDirection.ltr,
                textAlign: isRtlMsg ? TextAlign.right : TextAlign.left,
                style: const TextStyle(color: Color(0xFF00A884), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1),
              ),
            ),
          SelectableText(
            textValue,
            style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.3),
            textDirection: isRtlMsg ? TextDirection.rtl : TextDirection.ltr,
            textAlign: isRtlMsg ? TextAlign.right : TextAlign.left,
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            textDirection: isRtlMsg ? TextDirection.rtl : TextDirection.ltr,
            children: [
              Text(msg["time"], style: const TextStyle(color: _textDim, fontSize: 9)),
              const SizedBox(width: 4),
              if (msg["status"] == "error")
                GestureDetector(
                  onTap: () => _retryFailedMessageById(msgMid, msgTs),
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: const Center(
                      child: Icon(Icons.refresh, size: 14, color: Color(0xFF8696A0)),
                    ),
                  ),
                )
              else if (msg["status"] != "received")
                _buildStatusIcon(msg["status"]),
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

  Future<void> _retryFailedMessageById(String msgMid, int msgTs) async {
    if (msgMid.isEmpty && msgTs <= 0) return;
    if (_txInFlight) {
      if (_debugMode) print("DEBUG: TX already in flight, waiting...");
      return;
    }
    final msg = msgMid.isNotEmpty ? _findMessageByMid(msgMid) : _findMessageByTimestamp(msgTs);
    if (msg == null) {
      if (_debugMode) print("DEBUG: Message with mid=$msgMid ts=$msgTs not found");
      return;
    }
    if (msg["status"] != "error") return;

    _txInFlight = true;
    _txResetToken++;
    setState(() {
      msg["status"] = "sending";
      _status = NodeStatus.sending;
      _txActive = true;
      _txPercent = 0;
    });

    try {
      await _saveHistory();
      _setDebugInfo("TX: retrying...");
      final transport = DnsTransport(serverIP: _useDirectServer ? _serverIP : null, useTcp: _directTcp);
      final text = (msg["text"] ?? "").toString();
      var mid = (msg["mid"] ?? "").toString();
      List<dynamic>? chunks = msg["chunks"] is List ? (msg["chunks"] as List) : null;
      final timeoutMs = _dnsTimeoutMs();

      if (mid.isEmpty || chunks == null || chunks.isEmpty) {
        final encrypted = await PeykCrypto.encrypt(text);
        final b32 = base32.encode(encrypted).toLowerCase().replaceAll('=', '');
        final newChunks = _makeChunks(b32);
        mid = IdUtils.generateRandomID();
        msg["mid"] = mid;
        msg["chunks"] = newChunks;
        chunks = newChunks;
      }

      bool allAcked = true;
      for (int i = 0; i < chunks.length; i++) {
        final chunk = chunks[i].toString();
        final label = "${i + 1}-${chunks.length}-$mid-$_myID-$_targetID-$chunk";
        if (chunks.length > 6) {
          await Future.delayed(_sendChunkDelay);
        }
        bool acked = false;
        for (int r = 0; r <= _retryCount; r++) {
          Uint8List? response;
          if (_sendViaAAAA) {
            response = await transport.sendAndReceive("$label.$_baseDomain", qtype: 28, timeoutMs: timeoutMs);
            if (response == null && _fallbackEnabled) {
              response = await transport.sendAndReceive("$label.$_baseDomain", qtype: 1, timeoutMs: timeoutMs);
            }
          } else {
            response = await transport.sendAndReceive("$label.$_baseDomain", qtype: 1, timeoutMs: timeoutMs);
          }
          if (response != null) {
            acked = true;
            break;
          }
          if (r < _retryCount) {
            await Future.delayed(const Duration(milliseconds: 120));
          }
        }
        if (!acked) {
          allAcked = false;
          break;
        }
        final pct = (((i + 1) * 100) / chunks.length).floor();
        _setTxPercent(pct);
      }

      if (allAcked) {
        final ackKey = "${_myID.toLowerCase()}:${chunks.length}:$mid";
        msg["deliveryKey"] = ackKey;
        _pendingDelivery[ackKey] = 1;
        _pendingLastSent[ackKey] = DateTime.now();
        setState(() {
          msg["status"] = "sent";
          _status = NodeStatus.success;
          _txPercent = 100;
        });
        await _saveHistory();
      } else {
        setState(() {
          msg["status"] = "error";
          _status = NodeStatus.error;
        });
        await _saveHistory();
      }
    } catch (_) {
      setState(() {
        msg["status"] = "error";
        _status = NodeStatus.error;
        _txActive = false;
      });
      await _saveHistory();
    } finally {
      _resetTxStatus();
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _controller,
                    builder: (context, value, _) {
                      final inputRtl = _isRtlText(value.text);
                      return TextField(
                        controller: _controller,
                        focusNode: _inputFocus,
                        onTap: () => SystemChannels.textInput.invokeMethod('TextInput.show'),
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        minLines: 1,
                        maxLines: 4,
                        maxLength: _maxMessageChars,
                        maxLengthEnforcement: MaxLengthEnforcement.enforced,
                        textDirection: inputRtl ? TextDirection.rtl : TextDirection.ltr,
                        textAlign: inputRtl ? TextAlign.right : TextAlign.left,
                        style: const TextStyle(fontSize: 15, color: Colors.white),
                        decoration: InputDecoration(
                          hintText: "Message...",
                          hintStyle: const TextStyle(color: _textDim),
                          filled: true,
                          fillColor: const Color(0xFF202C33),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          counterText: "",
                        ),
                      );
                    },
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
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (context, value, _) {
                  final remaining = _maxMessageChars - value.text.characters.length;
                  return Text(
                    "$remaining/$_maxMessageChars",
                    style: const TextStyle(color: _textDim, fontSize: 10),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _inputFocus.dispose();
    _controller.dispose();
    _chatScrollCtrl.dispose();
    super.dispose();
  }
}
