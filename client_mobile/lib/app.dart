import 'package:flutter/material.dart';
import 'ui/chat_screen.dart';

class PeykDApp extends StatelessWidget {
  const PeykDApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Peyk-D Terminal',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B141A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00A884),
          surface: Color(0xFF182229),
        ),
        useMaterial3: true,
      ),
      home: const ChatScreen(),
    );
  }
}