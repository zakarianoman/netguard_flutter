import 'package:flutter/services.dart';

/// Active underlying network transport detected by the Android VPN service.
enum FirewallNetworkType {
  wifi,
  mobile,
  none;

  static FirewallNetworkType fromWire(String? value) {
    switch (value) {
      case 'wifi':
        return FirewallNetworkType.wifi;
      case 'mobile':
        return FirewallNetworkType.mobile;
      default:
        return FirewallNetworkType.none;
    }
  }

  String get displayLabel {
    switch (this) {
      case FirewallNetworkType.wifi:
        return 'Wi-Fi';
      case FirewallNetworkType.mobile:
        return 'Mobile Data';
      case FirewallNetworkType.none:
        return 'No Network';
    }
  }
}

/// Snapshot of the local VPN firewall state and active underlying network.
class FirewallStatus {
  const FirewallStatus({
    required this.isActive,
    required this.networkType,
  });

  static const FirewallStatus initial = FirewallStatus(
    isActive: false,
    networkType: FirewallNetworkType.none,
  );

  final bool isActive;
  final FirewallNetworkType networkType;

  factory FirewallStatus.fromMap(Map<Object?, Object?> map) {
    return FirewallStatus(
      isActive: map['isActive'] as bool? ?? false,
      networkType: FirewallNetworkType.fromWire(map['networkType'] as String?),
    );
  }
}

/// Exception thrown when communicating with the native VPN firewall fails.
class NativeFirewallServiceException implements Exception {
  const NativeFirewallServiceException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() =>
      code != null ? 'NativeFirewallServiceException($code): $message' : message;
}

/// Bridge for controlling [FirewallVpnService] and observing network switches.
class NativeFirewallService {
  NativeFirewallService({
    MethodChannel? methodChannel,
    EventChannel? statusEventChannel,
  })  : _methodChannel = methodChannel ?? _defaultMethodChannel,
        _statusEventChannel = statusEventChannel ?? _defaultStatusEventChannel;

  static const MethodChannel _defaultMethodChannel =
      MethodChannel('com.netguard.flutter/vpn');
  static const EventChannel _defaultStatusEventChannel =
      EventChannel('com.netguard.flutter/vpn_status');

  final MethodChannel _methodChannel;
  final EventChannel _statusEventChannel;

  /// Requests VPN consent if needed and starts [FirewallVpnService].
  /// Returns `true` if started, or `false` if the user declined VPN consent.
  Future<bool> startFirewall({
    required List<String> allowedWifiPackages,
    required List<String> allowedMobilePackages,
  }) async {
    try {
      final started = await _methodChannel.invokeMethod<bool>(
        'startFirewall',
        {
          'allowedWifiPackages': allowedWifiPackages,
          'allowedMobilePackages': allowedMobilePackages,
        },
      );
      return started ?? false;
    } on PlatformException catch (e) {
      throw NativeFirewallServiceException(
        e.message ?? 'Failed to start firewall.',
        code: e.code,
      );
    } on MissingPluginException {
      throw const NativeFirewallServiceException(
        'VPN firewall channel is unavailable on this platform.',
        code: 'MISSING_PLUGIN',
      );
    }
  }

  /// Stops [FirewallVpnService] if it is running.
  Future<void> stopFirewall() async {
    try {
      await _methodChannel.invokeMethod<void>('stopFirewall');
    } on PlatformException catch (e) {
      throw NativeFirewallServiceException(
        e.message ?? 'Failed to stop firewall.',
        code: e.code,
      );
    } on MissingPluginException {
      throw const NativeFirewallServiceException(
        'VPN firewall channel is unavailable on this platform.',
        code: 'MISSING_PLUGIN',
      );
    }
  }

  /// Pushes updated per-network allowed package lists to the active VPN service.
  Future<void> updateRules({
    required List<String> allowedWifiPackages,
    required List<String> allowedMobilePackages,
  }) async {
    try {
      await _methodChannel.invokeMethod<void>(
        'updateRules',
        {
          'allowedWifiPackages': allowedWifiPackages,
          'allowedMobilePackages': allowedMobilePackages,
        },
      );
    } on PlatformException catch (e) {
      throw NativeFirewallServiceException(
        e.message ?? 'Failed to update firewall rules.',
        code: e.code,
      );
    } on MissingPluginException {
      throw const NativeFirewallServiceException(
        'VPN firewall channel is unavailable on this platform.',
        code: 'MISSING_PLUGIN',
      );
    }
  }

  /// Fetches the current firewall running state and active network type.
  Future<FirewallStatus> getStatus() async {
    try {
      final raw = await _methodChannel.invokeMapMethod<Object?, Object?>('getStatus');
      if (raw == null) {
        return FirewallStatus.initial;
      }
      return FirewallStatus.fromMap(raw);
    } on PlatformException catch (e) {
      throw NativeFirewallServiceException(
        e.message ?? 'Failed to fetch firewall status.',
        code: e.code,
      );
    } on MissingPluginException {
      return FirewallStatus.initial;
    }
  }

  /// Broadcasts real-time firewall state and Wi-Fi/Mobile transitions from Android.
  Stream<FirewallStatus> get statusStream {
    return _statusEventChannel
        .receiveBroadcastStream()
        .where((event) => event is Map<Object?, Object?>)
        .map((event) => FirewallStatus.fromMap(event as Map<Object?, Object?>));
  }
}
