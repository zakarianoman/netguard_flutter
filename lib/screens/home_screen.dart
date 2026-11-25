import 'package:flutter/material.dart';

import '../models/app_info.dart';
import '../services/native_app_service.dart';

/// Main firewall screen displaying installed apps and per-network toggles.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, NativeAppService? appService})
      : _appService = appService;

  final NativeAppService? _appService;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final NativeAppService _appService;
  final TextEditingController _searchController = TextEditingController();

  List<AppInfo> _allApps = const [];
  bool _isLoading = true;
  String? _errorMessage;
  bool _showSystemApps = false;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _appService = widget._appService ?? NativeAppService();
    _loadApps();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadApps() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final apps = await _appService.getInstalledApps();
      if (!mounted) return;
      setState(() {
        _allApps = apps;
        _isLoading = false;
      });
    } on NativeAppServiceException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.message;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unexpected error loading apps: $e';
        _isLoading = false;
      });
    }
  }

  List<AppInfo> get _visibleApps {
    final query = _searchQuery.trim().toLowerCase();
    return _allApps.where((app) {
      if (!_showSystemApps && app.isSystemApp) {
        return false;
      }
      if (query.isEmpty) {
        return true;
      }
      return app.appName.toLowerCase().contains(query) ||
          app.packageName.toLowerCase().contains(query);
    }).toList(growable: false);
  }

  void _setVisibleAppsAccess(bool allow) {
    final visiblePackages =
        _visibleApps.map((app) => app.packageName).toSet();
    if (visiblePackages.isEmpty) return;

    setState(() {
      _allApps = _allApps
          .map(
            (app) => visiblePackages.contains(app.packageName)
                ? app.copyWith(allowWifi: allow, allowMobile: allow)
                : app,
          )
          .toList(growable: false);
    });
  }

  void _toggleWifi(String packageName) {
    setState(() {
      _allApps = _allApps
          .map(
            (app) => app.packageName == packageName
                ? app.copyWith(allowWifi: !app.allowWifi)
                : app,
          )
          .toList(growable: false);
    });
  }

  void _toggleMobile(String packageName) {
    setState(() {
      _allApps = _allApps
          .map(
            (app) => app.packageName == packageName
                ? app.copyWith(allowMobile: !app.allowMobile)
                : app,
          )
          .toList(growable: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final visibleApps = _visibleApps;

    return Scaffold(
      appBar: AppBar(
        title: const Text('NetGuard Firewall'),
        actions: [
          IconButton(
            tooltip: 'Refresh installed apps',
            onPressed: _isLoading ? null : _loadApps,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(context, visibleApps),
    );
  }

  Widget _buildBody(BuildContext context, List<AppInfo> visibleApps) {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading installed apps...'),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(
                'Failed to load installed apps',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                _errorMessage!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadApps,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        _buildTopControls(context, visibleApps),
        const Divider(height: 1),
        Expanded(
          child: visibleApps.isEmpty
              ? _buildEmptyState(context)
              : ListView.builder(
                  itemCount: visibleApps.length,
                  itemBuilder: (context, index) {
                    final app = visibleApps[index];
                    return _AppRuleTile(
                      app: app,
                      onToggleWifi: () => _toggleWifi(app.packageName),
                      onToggleMobile: () => _toggleMobile(app.packageName),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildTopControls(BuildContext context, List<AppInfo> visibleApps) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasVisibleApps = visibleApps.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _searchQuery = value),
            decoration: InputDecoration(
              hintText: 'Search apps by name...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChip(
                label: const Text('System apps'),
                selected: _showSystemApps,
                onSelected: (selected) {
                  setState(() => _showSystemApps = selected);
                },
              ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: hasVisibleApps
                        ? () => _setVisibleAppsAccess(false)
                        : null,
                    icon: Icon(
                      Icons.block,
                      size: 18,
                      color: hasVisibleApps ? colorScheme.error : null,
                    ),
                    label: Text(
                      'Block All',
                      style: TextStyle(
                        color: hasVisibleApps ? colorScheme.error : null,
                      ),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: hasVisibleApps
                        ? () => _setVisibleAppsAccess(true)
                        : null,
                    icon: const Icon(Icons.check_circle_outline, size: 18),
                    label: const Text('Allow All'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Showing ${visibleApps.length} of ${_allApps.length} apps',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.apps_outage_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              _searchQuery.isNotEmpty
                  ? 'No apps match "$_searchQuery"'
                  : 'No apps found',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _AppRuleTile extends StatelessWidget {
  const _AppRuleTile({
    required this.app,
    required this.onToggleWifi,
    required this.onToggleMobile,
  });

  final AppInfo app;
  final VoidCallback onToggleWifi;
  final VoidCallback onToggleMobile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: app.icon.isNotEmpty
                ? Image.memory(
                    app.icon,
                    width: 42,
                    height: 42,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  )
                : Container(
                    width: 42,
                    height: 42,
                    color: colorScheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.android,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        app.appName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (app.isSystemApp) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'SYS',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSecondaryContainer,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  app.packageName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _NetworkToggleIcon(
            label: 'Wi-Fi',
            allowed: app.allowWifi,
            allowedIcon: Icons.wifi,
            blockedIcon: Icons.wifi_off,
            onPressed: onToggleWifi,
          ),
          const SizedBox(width: 6),
          _NetworkToggleIcon(
            label: 'Data',
            allowed: app.allowMobile,
            allowedIcon: Icons.signal_cellular_alt,
            blockedIcon: Icons.signal_cellular_off,
            onPressed: onToggleMobile,
          ),
        ],
      ),
    );
  }
}

class _NetworkToggleIcon extends StatelessWidget {
  const _NetworkToggleIcon({
    required this.label,
    required this.allowed,
    required this.allowedIcon,
    required this.blockedIcon,
    required this.onPressed,
  });

  final String label;
  final bool allowed;
  final IconData allowedIcon;
  final IconData blockedIcon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foregroundColor =
        allowed ? colorScheme.primary : colorScheme.error;
    final backgroundColor = allowed
        ? colorScheme.primaryContainer.withOpacity(0.55)
        : colorScheme.errorContainer.withOpacity(0.55);

    return Tooltip(
      message: '$label: ${allowed ? "Allowed" : "Blocked"}',
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 48,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: foregroundColor.withOpacity(0.35),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                allowed ? allowedIcon : blockedIcon,
                size: 18,
                color: foregroundColor,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: foregroundColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
