import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netguard_flutter/models/app_info.dart';
import 'package:netguard_flutter/screens/home_screen.dart';
import 'package:netguard_flutter/services/native_app_service.dart';

class _FakeNativeAppService extends NativeAppService {
  _FakeNativeAppService(this._loader);

  final Future<List<AppInfo>> Function() _loader;

  @override
  Future<List<AppInfo>> getInstalledApps() => _loader();
}

void main() {
  final sampleApps = [
    AppInfo(
      appName: 'Browser',
      packageName: 'com.example.browser',
      isSystemApp: false,
      icon: Uint8List(0),
    ),
    AppInfo(
      appName: 'Notes',
      packageName: 'com.example.notes',
      isSystemApp: false,
      icon: Uint8List(0),
    ),
    AppInfo(
      appName: 'System Daemon',
      packageName: 'com.android.daemon',
      isSystemApp: true,
      icon: Uint8List(0),
    ),
  ];

  testWidgets('hides system apps by default and scopes Block/Allow All',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          appService: _FakeNativeAppService(() async => sampleApps),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Browser'), findsOneWidget);
    expect(find.text('Notes'), findsOneWidget);
    expect(find.text('System Daemon'), findsNothing);

    await tester.tap(find.text('Block All'));
    await tester.pump();

    expect(find.byIcon(Icons.wifi_off), findsNWidgets(2));
    expect(find.byIcon(Icons.signal_cellular_off), findsNWidgets(2));

    await tester.tap(find.text('System apps'));
    await tester.pump();

    expect(find.text('System Daemon'), findsOneWidget);
    expect(find.byIcon(Icons.wifi), findsOneWidget);
    expect(find.byIcon(Icons.signal_cellular_alt), findsOneWidget);

    await tester.tap(find.text('Allow All'));
    await tester.pump();

    expect(find.byIcon(Icons.wifi), findsNWidgets(3));
    expect(find.byIcon(Icons.signal_cellular_alt), findsNWidgets(3));
  });

  testWidgets('filters by search and toggles Wi-Fi & Data independently',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          appService: _FakeNativeAppService(() async => sampleApps),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Brow');
    await tester.pump();

    expect(find.text('Browser'), findsOneWidget);
    expect(find.text('Notes'), findsNothing);

    await tester.tap(find.byIcon(Icons.wifi));
    await tester.pump();

    expect(find.byIcon(Icons.wifi_off), findsOneWidget);
    expect(find.byIcon(Icons.signal_cellular_alt), findsOneWidget);
  });

  testWidgets('displays error state and retries cleanly',
      (WidgetTester tester) async {
    var shouldFail = true;
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          appService: _FakeNativeAppService(() async {
            if (shouldFail) {
              throw const NativeAppServiceException('Permission denied');
            }
            return sampleApps;
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Permission denied'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    shouldFail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Browser'), findsOneWidget);
  });
}
