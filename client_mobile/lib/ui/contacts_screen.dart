import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/id.dart';
import 'chat_screen.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  static const String _contactsKey = 'contacts_list';
  static const String _contactNamesKey = 'contacts_names';

  String _myId = '';
  List<String> _contacts = [];
  Map<String, String> _names = {};

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
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
    setState(() {
      _myId = myId;
      _contacts = contacts.where(IdUtils.isValid).toList();
      _names = names;
    });
  }

  Future<void> _saveContacts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_contactsKey, _contacts);
    await prefs.setString(_contactNamesKey, jsonEncode(_names));
  }

  void _openChat(String targetId) {
    final displayName = _names[targetId];
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(targetId: targetId, displayName: displayName)),
    );
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
          backgroundColor: const Color(0xFF182229),
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
                  fillColor: Colors.black26,
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
                  fillColor: Colors.black26,
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
        backgroundColor: const Color(0xFF182229),
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
            fillColor: Colors.black26,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("CONTACTS", style: TextStyle(letterSpacing: 3, fontSize: 12, fontWeight: FontWeight.bold)),
        actions: [IconButton(icon: const Icon(Icons.add, size: 20), onPressed: _showAddContact)],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            child: Text("YOUR NODE: $_myId",
                style: const TextStyle(color: Color(0xFF00A884), fontSize: 9, fontFamily: 'monospace')),
          ),
          Expanded(
            child: _contacts.isEmpty
                ? const Center(child: Text("No contacts yet", style: TextStyle(color: Colors.white38, fontSize: 12)))
                : ListView.separated(
                    itemCount: _contacts.length,
                    separatorBuilder: (_, __) => const Divider(color: Colors.white10, height: 1),
                    itemBuilder: (context, index) {
                      final id = _contacts[index];
                      final displayName = _names[id];
                      return ListTile(
                        title: Text(displayName?.isNotEmpty == true ? displayName! : id,
                            style: const TextStyle(color: Colors.white)),
                        subtitle: displayName?.isNotEmpty == true
                            ? Text(id, style: const TextStyle(color: Colors.white38, fontSize: 11))
                            : null,
                        leading: const Icon(Icons.person, color: Color(0xFF00A884), size: 18),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, color: Colors.white24, size: 18),
                              onPressed: () => _showEditName(id),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.white24, size: 18),
                              onPressed: () => _removeContact(id),
                            ),
                          ],
                        ),
                        onTap: () => _openChat(id),
                      );
                    },
                  ),
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
