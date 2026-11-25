import 'package:flutter/services.dart';

import '../models/app_info.dart';

/// Exception thrown when retrieving installed applications from the native layer fails.
class NativeAppServiceException implements Exception {
  const NativeAppServiceException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() =>
      code != null ? 'NativeAppServiceException($code): $message' : message;
}

/// Service for communicating with Android's PackageManager via MethodChannel.
class NativeAppService {
  NativeAppService({MethodChannel? channel})
      : _channel = channel ?? _defaultChannel;

  static const MethodChannel _defaultChannel =
      MethodChannel('com.netguard.flutter/apps');
  static const String _getInstalledAppsMethod = 'getInstalledApps';

  final MethodChannel _channel;

  /// Fetches installed apps from native Android and sorts them alphabetically.
  Future<List<AppInfo>> getInstalledApps() async {
    try {
      final rawList =
          await _channel.invokeListMethod<Object?>(_getInstalledAppsMethod);
      if (rawList == null) {
        return const [];
      }

      final apps = <AppInfo>[];
      for (final item in rawList) {
        if (item is Map<Object?, Object?>) {
          apps.add(AppInfo.fromMap(item));
        }
      }

      apps.sort(
        (a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()),
      );
      return apps;
    } on PlatformException catch (e) {
      throw NativeAppServiceException(
        e.message ?? 'Unable to load installed applications.',
        code: e.code,
      );
    } on MissingPluginException {
      throw const NativeAppServiceException(
        'Native app channel is unavailable on this platform.',
        code: 'MISSING_PLUGIN',
      );
    }
  }
}
