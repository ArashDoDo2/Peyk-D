import 'package:flutter/material.dart';
import 'core/notifications.dart';
import 'ui/contacts_screen.dart';

class PeykDApp extends StatefulWidget {
  const PeykDApp({super.key});

  @override
  State<PeykDApp> createState() => _PeykDAppState();
}

class _PeykDAppState extends State<PeykDApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    NotificationService.isForeground = state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Peyk-D Terminal',
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: 'monospace',
        scaffoldBackgroundColor: const Color(0xFF0B141A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00A884),
          secondary: Color(0xFF25D366),
          surface: Color(0xFF111B21),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF111B21),
          foregroundColor: Color(0xFFE9EDEF),
          elevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF202C33),
          hintStyle: const TextStyle(color: Color(0xFF8696A0)),
          labelStyle: const TextStyle(color: Color(0xFF8696A0)),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        ),
        useMaterial3: true,
      ),
      home: const ContactsScreen(),
    );
  }
}
