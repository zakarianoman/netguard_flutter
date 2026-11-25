import 'dart:typed_data';

/// Represents an installed Android application and its per-network firewall rules.
class AppInfo {
  const AppInfo({
    required this.appName,
    required this.packageName,
    required this.isSystemApp,
    required this.icon,
    this.allowWifi = true,
    this.allowMobile = true,
  });

  final String appName;
  final String packageName;
  final bool isSystemApp;
  final Uint8List icon;
  final bool allowWifi;
  final bool allowMobile;

  /// Creates an [AppInfo] instance from a platform-channel map payload.
  factory AppInfo.fromMap(Map<Object?, Object?> map) {
    final rawIcon = map['icon'];
    final Uint8List iconBytes;
    if (rawIcon is Uint8List) {
      iconBytes = rawIcon;
    } else if (rawIcon is List<int>) {
      iconBytes = Uint8List.fromList(rawIcon);
    } else {
      iconBytes = Uint8List(0);
    }

    final packageName = map['packageName'] as String? ?? '';
    final rawName = map['appName'] as String? ?? '';

    return AppInfo(
      appName: rawName.isNotEmpty ? rawName : packageName,
      packageName: packageName,
      isSystemApp: map['isSystemApp'] as bool? ?? false,
      icon: iconBytes,
      allowWifi: map['allowWifi'] as bool? ?? true,
      allowMobile: map['allowMobile'] as bool? ?? true,
    );
  }

  /// Returns a copy of this [AppInfo] with the provided fields updated.
  AppInfo copyWith({
    String? appName,
    String? packageName,
    bool? isSystemApp,
    Uint8List? icon,
    bool? allowWifi,
    bool? allowMobile,
  }) {
    return AppInfo(
      appName: appName ?? this.appName,
      packageName: packageName ?? this.packageName,
      isSystemApp: isSystemApp ?? this.isSystemApp,
      icon: icon ?? this.icon,
      allowWifi: allowWifi ?? this.allowWifi,
      allowMobile: allowMobile ?? this.allowMobile,
    );
  }
}
