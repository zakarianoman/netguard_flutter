import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netguard_flutter/models/app_info.dart';
import 'package:netguard_flutter/screens/home_screen.dart';
import 'package:netguard_flutter/services/native_app_service.dart';
import 'package:netguard_flutter/services/native_firewall_service.dart';
import 'package:netguard_flutter/services/rule_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeNativeAppService extends NativeAppService {
  _FakeNativeAppService(this._loader);

  final Future<List<AppInfo>> Function() _loader;

  @override
  Future<List<AppInfo>> getInstalledApps() => _loader();
}

class _FakeNativeFirewallService extends NativeFirewallService {
  _FakeNativeFirewallService({
    this.grantPermission = true,
    FirewallStatus initialStatus = const FirewallStatus(
      isActive: false,
      networkType: FirewallNetworkType.wifi,
    ),
  }) : _status = initialStatus;

  final bool grantPermission;
  FirewallStatus _status;
  final _controller = StreamController<FirewallStatus>.broadcast();

  List<String> lastAllowedWifi = const [];
  List<String> lastAllowedMobile = const [];
  int updateCallCount = 0;

  @override
  Future<FirewallStatus> getStatus() async => _status;

  @override
  Stream<FirewallStatus> get statusStream => _controller.stream;

  @override
  Future<bool> startFirewall({
    required List<String> allowedWifiPackages,
    required List<String> allowedMobilePackages,
  }) async {
    if (!grantPermission) return false;
    lastAllowedWifi = allowedWifiPackages;
    lastAllowedMobile = allowedMobilePackages;
    _status = FirewallStatus(
      isActive: true,
      networkType: _status.networkType,
    );
    _controller.add(_status);
    return true;
  }

  @override
  Future<void> stopFirewall() async {
    _status = FirewallStatus(
      isActive: false,
      networkType: _status.networkType,
    );
    _controller.add(_status);
  }

  @override
  Future<void> updateRules({
    required List<String> allowedWifiPackages,
    required List<String> allowedMobilePackages,
  }) async {
    updateCallCount++;
    lastAllowedWifi = allowedWifiPackages;
    lastAllowedMobile = allowedMobilePackages;
  }

  void emitNetworkChange(FirewallNetworkType networkType) {
    _status = FirewallStatus(isActive: _status.isActive, networkType: networkType);
    _controller.add(_status);
  }

  Future<void> dispose() => _controller.close();
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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('hides system apps by default and scopes Block/Allow All',
      (WidgetTester tester) async {
    final fakeVpn = _FakeNativeFirewallService();
    addTearDown(fakeVpn.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          appService: _FakeNativeAppService(() async => sampleApps),
          firewallService: fakeVpn,
          ruleStorageService: RuleStorageService(),
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
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byIcon(Icons.wifi),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byIcon(Icons.signal_cellular_alt),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Allow All'));
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byIcon(Icons.wifi),
      ),
      findsNWidgets(3),
    );
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byIcon(Icons.signal_cellular_alt),
      ),
      findsNWidgets(3),
    );
  });

  testWidgets('loads saved rules, toggles firewall, and pushes live rule updates',
      (WidgetTester tester) async {
    final storage = RuleStorageService();
    await storage.saveRules([
      sampleApps[0].copyWith(allowWifi: false, allowMobile: true),
      sampleApps[1],
      sampleApps[2],
    ]);

    final fakeVpn = _FakeNativeFirewallService();
    addTearDown(fakeVpn.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          appService: _FakeNativeAppService(() async => sampleApps),
          firewallService: fakeVpn,
          ruleStorageService: storage,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Protection Paused'), findsOneWidget);
    expect(find.text('Network: Wi-Fi'), findsOneWidget);
    // Persisted rule for Browser kept Wi-Fi blocked.
    expect(find.byIcon(Icons.wifi_off), findsOneWidget);

    // Enable master switch.
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.text('Protection Active'), findsOneWidget);
    expect(fakeVpn.lastAllowedWifi, ['com.example.notes', 'com.android.daemon']);
    expect(
      fakeVpn.lastAllowedMobile,
      ['com.example.browser', 'com.example.notes', 'com.android.daemon'],
    );

    // Network switches to Mobile Data in background -> UI updates in real time.
    fakeVpn.emitNetworkChange(FirewallNetworkType.mobile);
    await tester.pumpAndSettle();
    expect(find.text('Network: Mobile Data'), findsOneWidget);

    // Toggle Notes' Wi-Fi while active -> pushes updateRules immediately.
    await tester.tap(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byIcon(Icons.wifi),
      ).first,
    );
    await tester.pumpAndSettle();
    expect(fakeVpn.updateCallCount, 1);
    expect(fakeVpn.lastAllowedWifi, ['com.android.daemon']);

    final reloaded = await storage.loadRules();
    expect(reloaded['com.example.notes']?.allowWifi, isFalse);
  });

  testWidgets('displays error state and retries cleanly',
      (WidgetTester tester) async {
    final fakeVpn = _FakeNativeFirewallService();
    addTearDown(fakeVpn.dispose);
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
          firewallService: fakeVpn,
          ruleStorageService: RuleStorageService(),
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

  testWidgets('keeps firewall off and shows SnackBar if VPN consent is denied',
      (WidgetTester tester) async {
    final fakeVpn = _FakeNativeFirewallService(grantPermission: false);
    addTearDown(fakeVpn.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          appService: _FakeNativeAppService(() async => sampleApps),
          firewallService: fakeVpn,
          ruleStorageService: RuleStorageService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.text('Protection Paused'), findsOneWidget);
    expect(
      find.text('VPN permission is required to enable the firewall.'),
      findsOneWidget,
    );
  });
}
