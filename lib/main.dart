import 'package:flutter/material.dart';

import 'screens/scan_screen.dart';

void main() {
  runApp(const WitMotionDemoApp());
}

class WitMotionDemoApp extends StatelessWidget {
  const WitMotionDemoApp({super.key, this.home});

  /// Overridable for widget tests (BLE isn't available there).
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0A7CFF);
    return MaterialApp(
      title: 'WitMotion Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: home ?? const ScanScreen(),
    );
  }
}
