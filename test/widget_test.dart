import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:witmotion_demo/main.dart';

void main() {
  testWidgets('app shell builds', (tester) async {
    await tester.pumpWidget(const WitMotionDemoApp(home: Scaffold(body: Text('ok'))));
    expect(find.text('ok'), findsOneWidget);
  });
}
