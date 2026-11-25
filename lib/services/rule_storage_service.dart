import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_info.dart';

/// Saved per-network access rules for a single package.
class AppFirewallRule {
  const AppFirewallRule({
    required this.allowWifi,
    required this.allowMobile,
  });

  final bool allowWifi;
  final bool allowMobile;

  Map<String, bool> toJson() => {
        'allowWifi': allowWifi,
        'allowMobile': allowMobile,
      };

  factory AppFirewallRule.fromJson(Map<String, dynamic> json) {
    return AppFirewallRule(
      allowWifi: json['allowWifi'] as bool? ?? true,
      allowMobile: json['allowMobile'] as bool? ?? true,
    );
  }
}

/// Persists per-app Wi-Fi and Mobile Data firewall rules using SharedPreferences.
class RuleStorageService {
  static const String _rulesKey = 'app_firewall_rules_v1';

  /// Loads saved rules keyed by package name.
  Future<Map<String, AppFirewallRule>> loadRules() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_rulesKey);
    if (raw == null || raw.isEmpty) {
      return const {};
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const {};
      }

      final rules = <String, AppFirewallRule>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is Map<String, dynamic>) {
          rules[entry.key] = AppFirewallRule.fromJson(value);
        }
      }
      return rules;
    } catch (_) {
      return const {};
    }
  }

  /// Saves all apps' current [allowWifi] and [allowMobile] rules locally.
  Future<void> saveRules(List<AppInfo> apps) async {
    final prefs = await SharedPreferences.getInstance();
    final encodedMap = <String, Map<String, bool>>{};
    for (final app in apps) {
      encodedMap[app.packageName] = AppFirewallRule(
        allowWifi: app.allowWifi,
        allowMobile: app.allowMobile,
      ).toJson();
    }
    await prefs.setString(_rulesKey, jsonEncode(encodedMap));
  }
}
