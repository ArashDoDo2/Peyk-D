import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/notifications.dart';
import '../core/protocol.dart';
import '../core/rx_assembly.dart';
import '../core/transport.dart';
import '../core/decode_worker.dart';
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
  static const String _changelogV1 = """
CHANGELOG - Version 1.1
2026-01-17 12:00 - v1.1 - TX retry button + safe retry by mid/ts
2026-01-17 12:00 - v1.1 - ACK2 resend for late chunks
2026-01-17 12:00 - v1.1 - DNS timeout tuned for 350-400ms RTT
2026-01-17 12:00 - v1.1 - Polling burst tuning and RX guardrails
2026-01-17 12:00 - v1.1 - Font sizes improved in chat/contacts
2026-01-17 02:08 - Polling improvements
2026-01-17 02:01 - RX buffer fixes
2026-01-17 01:16 - Decode/Decrypt moved to isolate
2026-01-16 22:54 - ACK2 in polling
2026-01-16 14:06 - Contact name support
2026-01-16 13:21 - RTL rendering fixes
2026-01-16 13:16 - Advanced settings + location modes
2026-01-16 11:58 - Backoff handling
2026-01-15 17:02 - Base protocol cleanup
2026-01-15 02:16 - TXT -> AAAA/A migration
2026-01-14 18:51 - RX error handling
2026-01-13 16:52 - DNS transport refactor
""";

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
  bool _directTcp = false;
  bool _sendViaAAAA = false;
  bool _debugMode = false;
  int _pollMin = 20;
  int _pollMax = 40;
  int _retryCount = 3;
  String _baseDomain = PeykProtocol.baseDomain;
  String _serverIP = PeykProtocol.defaultServerIP;
  String _locationMode = "iran";
  final Map<String, _RxBufferState> _buffers = {};

  static const int _contactsPollSeconds = 30;
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
      _myId = myId;
      _contacts = contacts.where(IdUtils.isValid).toList();
      _names = names;
      _unread = unread;
      _pollMin = prefs.getInt('poll_min') ?? 3;
      _pollMax = prefs.getInt('poll_max') ?? 10;
      _retryCount = prefs.getInt('retry_count') ?? 3;
      _pollingEnabled = prefs.getBool('polling_enabled') ?? true;
      _debugMode = prefs.getBool('debug_mode') ?? false;
      _fallbackEnabled = prefs.getBool('fallback_enabled') ?? true;
      _useDirectServer = prefs.getBool('use_direct_server') ?? false;
      _directTcp = prefs.getBool('direct_tcp') ?? false;
      _sendViaAAAA = prefs.getBool('send_via_aaaa') ?? false;
      _baseDomain = prefs.getString('base_domain') ?? PeykProtocol.baseDomain;
      _serverIP = prefs.getString('server_ip') ?? PeykProtocol.defaultServerIP;
      _locationMode = nextLocation;

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
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  labelText: "Node ID",
                  hintText: "abcde",
                  errorText: error,
                  prefixIcon: const Icon(Icons.person_add, size: 18, color: Color(0xFF00A884)),
                  labelStyle: const TextStyle(color: Colors.white54, fontSize: 13),
                  filled: true,
                  fillColor: const Color(0xFF202C33),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: nameCtrl,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  labelText: "Display Name (optional)",
                  hintText: "Nickname",
                  prefixIcon: const Icon(Icons.badge, size: 18, color: Color(0xFF00A884)),
                  labelStyle: const TextStyle(color: Colors.white54, fontSize: 13),
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
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            labelText: "Display Name",
            hintText: "Nickname",
            prefixIcon: const Icon(Icons.badge, size: 18, color: Color(0xFF00A884)),
            labelStyle: const TextStyle(color: Colors.white54, fontSize: 13),
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

  void _showSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final domainCtrl = TextEditingController();
    final ipCtrl = TextEditingController();
    final pollMinCtrl = TextEditingController();
    final pollMaxCtrl = TextEditingController();
    final retryCtrl = TextEditingController(text: _retryCount.toString());
    String locationMode = _locationMode;

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setL) => AlertDialog(
          backgroundColor: const Color(0xFF111B21),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: const Color(0xFF00A884).withOpacity(0.3))),
          title: const Text("SETTINGS", style: TextStyle(fontSize: 12, letterSpacing: 2, fontWeight: FontWeight.bold, color: Color(0xFF00A884))),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                      const Text("LOCATION", style: TextStyle(fontSize: 11, letterSpacing: 2, color: Color(0xFF8696A0))),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        value: locationMode,
                        dropdownColor: const Color(0xFF202C33),
                        decoration: InputDecoration(
                          floatingLabelBehavior: FloatingLabelBehavior.never,
                          hintText: "",
                          labelStyle: const TextStyle(color: Color(0xFF8696A0), fontSize: 13),
                          filled: true,
                          fillColor: const Color(0xFF202C33),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        ),
                          items: const [
                            DropdownMenuItem(
                              value: "iran",
                              child: Text("Iran", style: TextStyle(color: Colors.white, fontSize: 12), overflow: TextOverflow.ellipsis),
                            ),
                            DropdownMenuItem(
                              value: "other",
                              child: Text("Other Countries (Slow)", style: TextStyle(color: Colors.white, fontSize: 12), overflow: TextOverflow.ellipsis),
                            ),
                            DropdownMenuItem(
                              value: "other_direct",
                              child: Text("Other Countries (Fast)", style: TextStyle(color: Colors.white, fontSize: 12), overflow: TextOverflow.ellipsis),
                            ),
                            DropdownMenuItem(
                              value: "advanced",
                              child: Text("Advanced", style: TextStyle(color: Colors.white, fontSize: 12), overflow: TextOverflow.ellipsis),
                            ),
                          ],
                        onChanged: (value) {
                          if (value == null) return;
                            setL(() {
                              locationMode = value;
                              if (locationMode == "iran") {
                                _useDirectServer = false;
                                _directTcp = false;
                                _sendViaAAAA = true;
                                _fallbackEnabled = true;
                              } else if (locationMode == "other") {
                                _useDirectServer = true;
                                _directTcp = false;
                                _sendViaAAAA = true;
                                _fallbackEnabled = true;
                                ipCtrl.text = PeykProtocol.defaultServerIP;
                              } else if (locationMode == "other_direct") {
                                _useDirectServer = true;
                                _directTcp = true;
                                _sendViaAAAA = true;
                                _fallbackEnabled = true;
                                ipCtrl.text = PeykProtocol.defaultServerIP;
                              } else if (locationMode == "advanced") {
                                _directTcp = false;
                                ipCtrl.text = "";
                                domainCtrl.text = "";
                                pollMinCtrl.text = "";
                                pollMaxCtrl.text = "";
                            }
                          });
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                if (locationMode == "advanced")
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: const Color(0xFF111B21),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFF202C33)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("ADVANCED", style: TextStyle(fontSize: 11, letterSpacing: 2, color: Color(0xFF8696A0))),
                          _buildSettingField(ipCtrl, "Relay Server IP", Icons.lan, "Custom IP"),
                          _buildSettingField(domainCtrl, "Base Domain", Icons.dns, "Custom Domain"),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text("Direct Server", style: TextStyle(fontSize: 12, color: Colors.white70)),
                            value: _useDirectServer,
                            activeColor: const Color(0xFF00A884),
                            onChanged: (v) => setL(() => _useDirectServer = v),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text("Send via AAAA", style: TextStyle(fontSize: 12, color: Colors.white70)),
                            value: _sendViaAAAA,
                            activeColor: const Color(0xFF00A884),
                            onChanged: (v) => setL(() => _sendViaAAAA = v),
                          ),
                          Row(children: [
                            Expanded(child: _buildSettingField(pollMinCtrl, "Min Poll", Icons.timer_outlined, "Min >= 3", isNum: true)),
                            const SizedBox(width: 10),
                            Expanded(child: _buildSettingField(pollMaxCtrl, "Max Poll", Icons.timer, "Max >= Min", isNum: true)),
                          ]),
                          _buildSettingField(retryCtrl, "Retries", Icons.repeat, ">= 1", isNum: true),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text("Polling Enabled", style: TextStyle(fontSize: 12, color: Colors.white70)),
                            value: _pollingEnabled,
                            activeColor: const Color(0xFF00A884),
                            onChanged: (v) => setL(() => _pollingEnabled = v),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text("Fallback Enabled", style: TextStyle(fontSize: 12, color: Colors.white70)),
                            value: _fallbackEnabled,
                            activeColor: const Color(0xFF00A884),
                            onChanged: (v) => setL(() => _fallbackEnabled = v),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text("Debug Mode", style: TextStyle(fontSize: 12, color: Colors.white70)),
                            value: _debugMode,
                            activeColor: const Color(0xFF3E7BFA),
                            onChanged: (v) => setL(() => _debugMode = v),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("CANCEL", style: TextStyle(color: Colors.white30))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A884), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              onPressed: () async {
                final selectedLocation = locationMode;
                String nextServerIP = _serverIP;
                String nextDomain = _baseDomain;
                bool nextUseDirect = _useDirectServer;
                bool nextDirectTcp = _directTcp;
                bool nextSendViaAAAA = _sendViaAAAA;
                bool nextFallback = _fallbackEnabled;
                int nextPollMin = _pollMin;
                int nextPollMax = _pollMax;
                int nextRetryCount = _retryCount;

                if (selectedLocation == "iran") {
                  nextUseDirect = false;
                  nextDirectTcp = false;
                  nextSendViaAAAA = true;
                  nextFallback = true;
                  nextRetryCount = 3;
                } else if (selectedLocation == "other") {
                  nextUseDirect = true;
                  nextDirectTcp = false;
                  nextServerIP = PeykProtocol.defaultServerIP;
                  nextSendViaAAAA = true;
                  nextFallback = true;
                  nextRetryCount = 3;
                } else if (selectedLocation == "other_direct") {
                  nextUseDirect = true;
                  nextDirectTcp = true;
                  nextServerIP = PeykProtocol.defaultServerIP;
                  nextSendViaAAAA = true;
                  nextFallback = true;
                  nextRetryCount = 3;
                } else {
                  nextDirectTcp = _directTcp;
                  final nextIP = ipCtrl.text.trim();
                  final nextBase = domainCtrl.text.trim();
                  if (nextIP.isNotEmpty) {
                    nextServerIP = nextIP;
                  }
                  if (nextBase.isNotEmpty) {
                    nextDomain = nextBase;
                  }
                  final rawPollMin = int.tryParse(pollMinCtrl.text.trim());
                  final rawPollMax = int.tryParse(pollMaxCtrl.text.trim());
                  if (rawPollMin != null || rawPollMax != null) {
                    final minCandidate = rawPollMin ?? _pollMin;
                    final maxCandidate = rawPollMax ?? _pollMax;
                    nextPollMin = max(3, minCandidate);
                    nextPollMax = max(nextPollMin, maxCandidate);
                  }
                  final rawRetry = int.tryParse(retryCtrl.text.trim());
                  if (rawRetry != null && rawRetry > 0) {
                    nextRetryCount = rawRetry;
                  }
                }

                await prefs.setString('location_mode', selectedLocation);
                await prefs.setString('server_ip', nextServerIP);
                await prefs.setString('base_domain', nextDomain);
                await prefs.setInt('poll_min', nextPollMin);
                await prefs.setInt('poll_max', nextPollMax);
                await prefs.setInt('retry_count', nextRetryCount);
                await prefs.setBool('polling_enabled', _pollingEnabled);
                await prefs.setBool('debug_mode', _debugMode);
                await prefs.setBool('fallback_enabled', nextFallback);
                await prefs.setBool('use_direct_server', nextUseDirect);
                await prefs.setBool('direct_tcp', nextDirectTcp);
                await prefs.setBool('send_via_aaaa', nextSendViaAAAA);
                setState(() {
                  _pollMin = nextPollMin;
                  _pollMax = nextPollMax;
                  _retryCount = nextRetryCount;
                  _serverIP = nextServerIP;
                  _baseDomain = nextDomain;
                  _useDirectServer = nextUseDirect;
                  _directTcp = nextDirectTcp;
                  _sendViaAAAA = nextSendViaAAAA;
                  _fallbackEnabled = nextFallback;
                  _locationMode = selectedLocation;
                });
                _startPolling();
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
        style: const TextStyle(fontSize: 13, color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon, size: 18, color: const Color(0xFF00A884)),
          labelStyle: const TextStyle(color: Color(0xFF8696A0), fontSize: 12),
          filled: true,
          fillColor: const Color(0xFF202C33),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        ),
      ),
    );
  }

  Future<bool> _confirmDeleteContact(String id, String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF111B21),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: const Color(0xFFB00020).withOpacity(0.35)),
        ),
        title: const Text(
          "DELETE CONTACT",
          style: TextStyle(fontSize: 12, letterSpacing: 2, fontWeight: FontWeight.bold, color: Color(0xFFB00020)),
        ),
        content: Text(
          "Delete $title?\nThis will remove the contact and its unread counter.",
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("CANCEL", style: TextStyle(color: Colors.white30))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB00020), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("DELETE", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _showAbout() async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF111B21),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: const Color(0xFF00A884).withOpacity(0.3)),
        ),
        title: const Text(
          "درباره",
          style: TextStyle(fontSize: 12, letterSpacing: 2, fontWeight: FontWeight.bold, color: Color(0xFF00A884)),
        ),
        content: const Directionality(
          textDirection: TextDirection.ltr,
          child: Text(
            "این نرم افزار در دوره قطع کامل اینترنت ایران برای ایجاد یک کانال ارتباطی اضطراری ساخته شد. این یک پیامرسان کامل نیست و محدودیت های آن به دلیل تکیه بر حداقل امکانات ارتباطی موجود است.",
            style: TextStyle(fontSize: 12, color: Colors.white70, height: 1.5),
          ),
        ),
        actions: [
          TextButton(onPressed: _showChangelog, child: const Text("CHANGELOG", style: TextStyle(color: Color(0xFF00A884)))),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("CLOSE", style: TextStyle(color: Colors.white30))),
        ],
      ),
    );
  }

  Future<void> _showChangelog() async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF111B21),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: const Color(0xFF00A884).withOpacity(0.3)),
        ),
        title: const Text(
          "تاریخچه تغییرات",
          style: TextStyle(fontSize: 12, letterSpacing: 2, fontWeight: FontWeight.bold, color: Color(0xFF00A884)),
        ),
        content: Directionality(
            textDirection: TextDirection.ltr,
          child: SizedBox(
            width: double.maxFinite,
            height: 240,
            child: SingleChildScrollView(
              child: Text(
                  _changelogV1,
                  textAlign: TextAlign.left,
                  style: const TextStyle(fontSize: 12, color: Colors.white70, height: 1.5),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("CLOSE", style: TextStyle(color: Colors.white30))),
        ],
      ),
    );
  }

  void _startPolling() {
    _pollTimer?.cancel();
    if (!_pollingEnabled) return;
    _pollTimer = Timer.periodic(const Duration(seconds: _contactsPollSeconds), (_) => _fetchBuffer());
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

    final transport = DnsTransport(serverIP: _useDirectServer ? _serverIP : null, useTcp: _directTcp);
    bool hasMore = true;
    const int burstAttempts = 3;
    const int burstMinMs = 200;
    const int burstMaxMs = 400;
    const int maxLoops = 6;
    const int burstMaxLoops = 60;
    const Duration maxBudget = Duration(seconds: 3);
    const Duration burstBudget = Duration(seconds: 20);
    final startAt = DateTime.now();
    var lastProgressAt = startAt;
    int loops = 0;
    bool burstMode = false;

    while (hasMore) {
      if (!_pollingEnabled) break;
      final loopLimit = burstMode ? burstMaxLoops : maxLoops;
      final budgetLimit = burstMode ? burstBudget : maxBudget;
      final budgetStart = burstMode ? lastProgressAt : startAt;
      if (loops >= loopLimit || DateTime.now().difference(budgetStart) > budgetLimit) {
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
      if (!burstMode && looksFrame) {
        burstMode = true;
      }
      lastProgressAt = DateTime.now();

      if (!looksFrame) {
        await Future.delayed(burstMode ? const Duration(milliseconds: 80) : const Duration(milliseconds: 250));
      }
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
      final headerMatch = RegExp(r'\d+-\d+-[a-z2-7]{5}-[a-z2-7]{5}-[a-z2-7]{5}-').firstMatch(cleanTxt);
      if (headerMatch != null && headerMatch.start > 0) {
        cleanTxt = cleanTxt.substring(headerMatch.start) + cleanTxt.substring(0, headerMatch.start);
      }
    }

    final parts = cleanTxt.split("-");
    if (parts.length != 6) return;

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
    if (rid != _myId.toLowerCase()) return;
    if (payload.isEmpty) return;

    final bufKey = "$sid:$rid:$tot:$mid";
    final st = _buffers.putIfAbsent(bufKey, () => _RxBufferState(RxAssembly(sid, tot)));
    st.lastUpdatedAt = DateTime.now();
    st.asm.addFrame("$idx-$tot-$sid-$rid-$payload");

    if (st.asm.isComplete) {
      final String rawAssembled = st.asm.assemble();
      _buffers.remove(bufKey);

      try {
        final result = await compute(decodeAndDecrypt, {
          "raw": rawAssembled,
          "debug": false,
        });
        final decrypted = (result["decrypted"] as String?) ?? "Decryption error: empty result";
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

        final transport = DnsTransport(serverIP: _useDirectServer ? _serverIP : null, useTcp: _directTcp);
        final ackLabel = "ack2-$sid-$tot-$mid";
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
        title: const Text("CONTACTS", style: TextStyle(fontSize: 12, letterSpacing: 2, fontWeight: FontWeight.bold, color: Color(0xFF00A884))),
        actions: [
          IconButton(icon: const Icon(Icons.settings, size: 20), onPressed: _showSettings),
          IconButton(icon: const Icon(Icons.info_outline, size: 20), onPressed: _showAbout),
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
                          style: const TextStyle(color: Color(0xFF8696A0), fontSize: 12, letterSpacing: 1),
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
                  style: const TextStyle(fontSize: 14, color: Colors.white),
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
                            Text("No contacts yet", style: TextStyle(color: Color(0xFF8696A0), fontSize: 13)),
                            SizedBox(height: 4),
                            Text("Add your first contact to start chatting",
                                style: TextStyle(color: Color(0xFF5C6B75), fontSize: 11)),
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
                          return Dismissible(
                            key: ValueKey(id),
                            direction: DismissDirection.endToStart,
                            confirmDismiss: (_) => _confirmDeleteContact(id, title),
                            background: Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              decoration: BoxDecoration(
                                color: const Color(0xFFB00020),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              alignment: Alignment.centerRight,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: const [
                                  Icon(Icons.delete, color: Colors.white, size: 18),
                                  SizedBox(width: 6),
                                  Text("Delete", style: TextStyle(color: Colors.white, fontSize: 13)),
                                ],
                              ),
                            ),
                            onDismissed: (_) => _removeContact(id),
                            child: Material(
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
                                        decoration: const BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Color(0xFF25D366),
                                        ),
                                        child: Center(
                                          child: Text(initials, style: const TextStyle(color: Colors.white, fontSize: 15)),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(title, style: const TextStyle(color: Colors.white, fontSize: 15)),
                                            if (displayName?.isNotEmpty == true)
                                              Text(id, style: const TextStyle(color: Color(0xFF8696A0), fontSize: 12)),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.edit, color: Color(0xFF8696A0), size: 18),
                                        onPressed: () => _showEditName(id),
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
                                            style: const TextStyle(color: Colors.white, fontSize: 11),
                                          ),
                                        ),
                                    ],
                                  ),
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
