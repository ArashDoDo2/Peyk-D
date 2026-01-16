import 'package:flutter/material.dart';
import 'app.dart';
import 'core/notifications.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.initialize();
  runApp(const PeykDApp());
}
