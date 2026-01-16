import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:base32/base32.dart';

import '../core/crypto.dart';
import '../core/notifications.dart';
import '../core/rx_assembly.dart';
import '../core/transport.dart';
import '../utils/id.dart';
import 'chat_screen.dart';

class _RxBufferState {
  final RxAssembly asm;
  DateTime lastUpdatedAt;

  _RxBufferState(this.asm) : lastUpdatedAt = DateTime.now();
}

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  static const String _contactsKey = 'contacts_list';
  static const String _contactNamesKey = 'contacts_names';
  static const String _unreadKey = 'contacts_unread';

  String _myId = '';
  List<String> _contacts = [];
  Map<String, String> _names = {};
  Map<String, int> _unread = {};
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  Timer? _pollTimer;
  bool _pollingEnabled = true;
  bool _fallbackEnabled = false;
  bool _useDirectServer = false;
  int _pollMin = 20;
  int _pollMax = 40;
  String _baseDomain = 'p99.online.ir';
  String _serverIP = '';
  final Map<String, _RxBufferState> _buffers = {};

  static const Duration _bufferTtl = Duration(seconds: 90);

  @override
  void initState() {
    super.initState();
    _loadState();
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.trim().toLowerCase());
    });
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    final myId = prefs.getString('my_id') ?? IdUtils.generateRandomID();
    if (prefs.getString('my_id') == null) {
      await prefs.setString('my_id', myId);
    }
    final contacts = prefs.getStringList(_contactsKey) ?? <String>[];
    final rawNames = prefs.getString(_contactNamesKey);
    Map<String, String> names = {};
    if (rawNames != null && rawNames.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawNames);
        if (decoded is Map) {
          names = decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
      } catch (_) {
        // ignore bad names
      }
    }
    final rawUnread = prefs.getString(_unreadKey);
    Map<String, int> unread = {};
    if (rawUnread != null && rawUnread.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawUnread);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final key = entry.key.toString().toLowerCase();
            final val = int.tryParse(entry.value.toString()) ?? 0;
            if (val > 0) unread[key] = val;
          }
        }
      } catch (_) {
        // ignore bad unread
      }
    }
    if (!mounted) return;
    setState(() {
      _myId = myId;
      _contacts = contacts.where(IdUtils.isValid).toList();
      _names = names;
      _unread = unread;
      _pollMin = prefs.getInt('poll_min') ?? 20;
      _pollMax = prefs.getInt('poll_max') ?? 40;
      _pollingEnabled = prefs.getBool('polling_enabled') ?? true;
      _fallbackEnabled = prefs.getBool('fallback_enabled') ?? false;
      _useDirectServer = prefs.getBool('use_direct_server') ?? false;
      _baseDomain = prefs.getString('base_domain') ?? 'p99.online.ir';
      _serverIP = prefs.getString('server_ip') ?? '';
    });
    _startPolling();
  }

  Future<void> _saveContacts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_contactsKey, _contacts);
    await prefs.setString(_contactNamesKey, jsonEncode(_names));
  }

  Future<void> _openChat(String targetId) async {
    final displayName = _names[targetId];
    _pollTimer?.cancel();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(targetId: targetId, displayName: displayName)),
    );
    await _loadState();
  }

  String _displayNameForId(String id) {
    final name = _names[id];
    if (name != null && name.trim().isNotEmpty) return name;
    return id;
  }

  Future<void> _showAddContact() async {
    final ctrl = TextEditingController();
    final nameCtrl = TextEditingController();
    String? error;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          backgroundColor: const Color(0xFF111B21),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: const Color(0xFF00A884).withOpacity(0.3)),
          ),
          title: const Text("ADD CONTACT", style: TextStyle(fontSize: 12, letterSpacing: 2, fontWeight: FontWeight.bold, color: Color(0xFF00A884))),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  labelText: "Node ID",
                  hintText: "abcde",
                  errorText: error,
                  prefixIcon: const Icon(Icons.person_add, size: 18, color: Color(0xFF00A884)),
                  labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
                  filled: true,
                  fillColor: const Color(0xFF202C33),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: nameCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  labelText: "Display Name (optional)",
                  hintText: "Nickname",
                  prefixIcon: const Icon(Icons.badge, size: 18, color: Color(0xFF00A884)),
                  labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
                  filled: true,
                  fillColor: const Color(0xFF202C33),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("CANCEL", style: TextStyle(color: Colors.white30))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A884), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              onPressed: () async {
                final id = ctrl.text.trim().toLowerCase();
                if (!IdUtils.isValid(id)) {
                  setLocal(() => error = "Invalid ID");
                  return;
                }
                final name = nameCtrl.text.trim();
                if (!_contacts.contains(id)) {
                  setState(() => _contacts.add(id));
                }
                if (name.isNotEmpty) {
                  _names[id] = name;
                }
                await _saveContacts();
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text("ADD", style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _removeContact(String id) async {
    setState(() => _contacts.remove(id));
    _names.remove(id);
    await _saveContacts();
  }

  Future<void> _showEditName(String id) async {
    final ctrl = TextEditingController(text: _names[id] ?? "");
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF111B21),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: const Color(0xFF00A884).withOpacity(0.3)),
        ),
        title: const Text("EDIT NAME", style: TextStyle(fontSize: 12, letterSpacing: 2, fontWeight: FontWeight.bold, color: Color(0xFF00A884))),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            labelText: "Display Name",
            hintText: "Nickname",
            prefixIcon: const Icon(Icons.badge, size: 18, color: Color(0xFF00A884)),
            labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
            filled: true,
            fillColor: const Color(0xFF202C33),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("CANCEL", style: TextStyle(color: Colors.white30))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A884), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            onPressed: () async {
              final name = ctrl.text.trim();
              setState(() {
                if (name.isEmpty) {
                  _names.remove(id);
                } else {
                  _names[id] = name;
                }
              });
              await _saveContacts();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text("SAVE", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _startPolling() {
    _pollTimer?.cancel();
    if (!_pollingEnabled) return;
    final seconds = _pollMin + Random().nextInt(max(1, _pollMax - _pollMin + 1));
    _pollTimer = Timer.periodic(Duration(seconds: seconds), (_) => _fetchBuffer());
  }

  void _gcBuffers() {
    final now = DateTime.now();
    _buffers.removeWhere((_, st) => now.difference(st.lastUpdatedAt) > _bufferTtl);
  }

  String _bytesToText(Uint8List rawBytes) {
    final s = String.fromCharCodes(rawBytes);
    int end = s.length;
    while (end > 0 && s.codeUnitAt(end - 1) == 0) {
      end--;
    }
    return s.substring(0, end).trim();
  }

  Future<void> _fetchBuffer() async {
    if (!_pollingEnabled) return;
    _gcBuffers();

    final transport = DnsTransport(serverIP: _useDirectServer ? _serverIP : null);
    bool hasMore = true;
    const int burstAttempts = 3;
    const int burstMinMs = 200;
    const int burstMaxMs = 400;
    const int maxLoops = 6;
    const Duration maxBudget = Duration(seconds: 3);
    final startAt = DateTime.now();
    int loops = 0;

    while (hasMore) {
      if (!_pollingEnabled) break;
      if (loops >= maxLoops || DateTime.now().difference(startAt) > maxBudget) {
        break;
      }
      loops++;

      Uint8List? rawBytes;
      String txt = "";
      var usedAAAA = true;
      bool looksFrame = false;

      for (int attempt = 0; attempt < burstAttempts; attempt++) {
        final pollNonce = IdUtils.generateRandomID();
        var response = await transport.sendAndReceive("v1.sync.$_myId.$pollNonce.$_baseDomain", qtype: 28);
        usedAAAA = true;
        if (response == null && _fallbackEnabled) {
          response = await transport.sendAndReceive("v1.sync.$_myId.$pollNonce.$_baseDomain", qtype: 1);
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
          response = await transport.sendAndReceive("v1.sync.$_myId.$pollNonce.$_baseDomain", qtype: 1);
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
          response = await transport.sendAndReceive("v1.sync.$_myId.$pollNonce.$_baseDomain", qtype: 1);
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
      if (!looksFrame) {
        continue;
      }

      if (txt.startsWith("ACK2-")) {
        // ignore, only delivery status for sender
      } else {
        await _handleIncomingChunk(txt);
      }

      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> _appendToHistoryForTarget(String targetId, Map<String, dynamic> msg) async {
    final prefs = await SharedPreferences.getInstance();
    final key = "chat_history_${_myId.toLowerCase()}_${targetId.toLowerCase()}";
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
    await prefs.setString(key, jsonEncode(items.take(200).toList()));
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
    if (!mounted) return;
    setState(() => _unread = counts);
  }

  Future<void> _handleIncomingChunk(String txt) async {
    final cleanBuffer = StringBuffer();
    for (int i = 0; i < txt.length; i++) {
      final c = txt.codeUnitAt(i);
      if (c >= 32 && c <= 126) cleanBuffer.writeCharCode(c);
    }
    String cleanTxt = cleanBuffer.toString().trim().toLowerCase();

    if (!RegExp(r'^\d+-').hasMatch(cleanTxt)) {
      final headerMatch = RegExp(r'\d+-\d+-[a-z2-7]{5}-[a-z2-7]{5}-[a-z2-7]{5}-').firstMatch(cleanTxt) ??
          RegExp(r'\d+-\d+-[a-z2-7]{5}-[a-z2-7]{5}-').firstMatch(cleanTxt);
      if (headerMatch != null && headerMatch.start > 0) {
        cleanTxt = cleanTxt.substring(headerMatch.start) + cleanTxt.substring(0, headerMatch.start);
      }
    }

    final parts = cleanTxt.split("-");
    if (parts.length != 5 && parts.length != 6) return;

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
    if (rid != _myId.toLowerCase()) return;
    if (payload.isEmpty) return;

    final bufKey = mid.isEmpty ? "$sid:$rid:$tot" : "$sid:$rid:$tot:$mid";
    final st = _buffers.putIfAbsent(bufKey, () => _RxBufferState(RxAssembly(sid, tot)));
    st.lastUpdatedAt = DateTime.now();
    st.asm.addFrame("$idx-$tot-$sid-$rid-$payload");

    if (st.asm.isComplete) {
      final String rawAssembled = st.asm.assemble();
      _buffers.remove(bufKey);

      String normalized = rawAssembled.toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');
      while (normalized.length % 8 != 0) {
        normalized += '=';
      }

      try {
        final decoded = Uint8List.fromList(base32.decode(normalized));
        final decrypted = await PeykCrypto.decrypt(decoded);
        if (decrypted.startsWith("Error") || decrypted.startsWith("Decryption error")) {
          return;
        }
        await _appendToHistoryForTarget(sid, {
          "text": decrypted,
          "status": "received",
          "from": sid,
          "time": _getTime(),
        });
        await _incrementUnread(sid);
        await NotificationService.showIncomingMessage(_displayNameForId(sid), decrypted);

        final transport = DnsTransport(serverIP: _useDirectServer ? _serverIP : null);
        final ackLabel = mid.isEmpty ? "ack2-$sid-$tot" : "ack2-$sid-$tot-$mid";
        final ackNonceA = IdUtils.generateRandomID();
        final ackNonceAAAA = IdUtils.generateRandomID();
        await transport.sendOnly("$ackLabel.$ackNonceA.$_baseDomain", qtype: 1);
        await transport.sendOnly("$ackLabel.$ackNonceAAAA.$_baseDomain", qtype: 28);
      } catch (_) {
        // ignore decode failures
      }
    }
  }

  String _getTime() => "${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}";

  @override
  void dispose() {
    _pollTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _query.isEmpty
        ? _contacts
        : _contacts.where((id) {
            final name = (_names[id] ?? '').toLowerCase();
            return id.contains(_query) || name.contains(_query);
          }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text("CONTACTS", style: TextStyle(letterSpacing: 3, fontSize: 12, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(icon: const Icon(Icons.add, size: 20), onPressed: _showAddContact),
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
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF111B21),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF202C33)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Color(0xFF00A884),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "YOUR NODE: $_myId",
                          style: const TextStyle(color: Color(0xFF8696A0), fontSize: 10, letterSpacing: 1),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextField(
                  controller: _searchCtrl,
                  style: const TextStyle(fontSize: 13, color: Colors.white),
                  decoration: InputDecoration(
                    hintText: "Search contacts...",
                    prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF8696A0)),
                    filled: true,
                    fillColor: const Color(0xFF202C33),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  ),
                ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(Icons.person_search, color: Color(0xFF374248), size: 32),
                            SizedBox(height: 10),
                            Text("No contacts yet", style: TextStyle(color: Color(0xFF8696A0), fontSize: 12)),
                            SizedBox(height: 4),
                            Text("Add your first contact to start chatting",
                                style: TextStyle(color: Color(0xFF5C6B75), fontSize: 10)),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 80),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final id = filtered[index];
                          final displayName = _names[id];
                          final title = displayName?.isNotEmpty == true ? displayName! : id;
                          final initials = title.isNotEmpty ? title[0].toUpperCase() : "?";
                          final unread = _unread[id] ?? 0;
                          return Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () => _openChat(id),
                              child: Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                  color: const Color(0xFF111B21),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: const Color(0xFF202C33)),
                                ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: const Color(0xFF25D366),
                                    ),
                                    child: Center(
                                      child: Text(initials, style: const TextStyle(color: Colors.white, fontSize: 14)),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(title, style: const TextStyle(color: Colors.white, fontSize: 13)),
                                        if (displayName?.isNotEmpty == true)
                                          Text(id, style: const TextStyle(color: Color(0xFF8696A0), fontSize: 10)),
                                      ],
                                    ),
                                  ),
                                    IconButton(
                                      icon: const Icon(Icons.edit, color: Color(0xFF8696A0), size: 18),
                                      onPressed: () => _showEditName(id),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete, color: Color(0xFF8696A0), size: 18),
                                      onPressed: () => _removeContact(id),
                                    ),
                                    if (unread > 0)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF00A884),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Text(
                                          unread > 99 ? "99+" : unread.toString(),
                                          style: const TextStyle(color: Colors.white, fontSize: 10),
                                        ),
                                      )
                                    else
                                      IconButton(
                                        icon: const Icon(Icons.chevron_right, color: Color(0xFF00A884), size: 18),
                                        onPressed: () => _openChat(id),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF00A884),
        onPressed: _showAddContact,
        child: const Icon(Icons.person_add, color: Colors.white),
      ),
    );
  }
}
