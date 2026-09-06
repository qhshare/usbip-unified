import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:usbip_unified/main.dart';

void main() {
  testWidgets('renders the USB/IP manager', (WidgetTester tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: ManagerPage(autoRefresh: false)));

    expect(find.text('USBIP Unified'), findsOneWidget);
    expect(find.text('统一管理本机与远程 USB 设备'), findsOneWidget);
  });
}
