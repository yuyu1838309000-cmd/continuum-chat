import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'features/chat/chat_screen.dart';
import 'features/history/history_screen.dart';
import 'features/memory/memory_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/tools/tools_screen.dart';
import 'services/api_client.dart';
import 'services/server_config.dart';

class ContinuumApp extends StatefulWidget {
  const ContinuumApp({
    super.key,
    this.initialConfig = const ServerConfig(),
    this.preferences,
    this.httpClient,
  });

  final ServerConfig initialConfig;
  final SharedPreferences? preferences;
  final http.Client? httpClient;

  @override
  State<ContinuumApp> createState() => _ContinuumAppState();
}

class _ContinuumAppState extends State<ContinuumApp> {
  late ServerConfig _config = widget.initialConfig;

  Future<void> _saveConfig(ServerConfig config) async {
    if (widget.preferences case final preferences?) {
      await config.save(preferences);
    }
    setState(() => _config = config);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Continuum Chat',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff3f5f63),
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: const Color(0xfff7f8f6),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xfff7f8f6),
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      useMaterial3: true,
    ),
    home: NavigationShell(
      key: ValueKey(
        '${_config.scheme}:${_config.host}:${_config.runtimePort}:${_config.memoryPort}:${_config.token}',
      ),
      config: _config,
      onSaveConfig: _saveConfig,
      httpClient: widget.httpClient,
    ),
  );
}

class NavigationShell extends StatefulWidget {
  const NavigationShell({
    super.key,
    required this.config,
    required this.onSaveConfig,
    this.httpClient,
  });

  final ServerConfig config;
  final Future<void> Function(ServerConfig) onSaveConfig;
  final http.Client? httpClient;

  @override
  State<NavigationShell> createState() => _NavigationShellState();
}

class _NavigationShellState extends State<NavigationShell> {
  int _index = 0;
  late final ApiClient _api = ApiClient(
    widget.config,
    httpClient: widget.httpClient,
  );
  late final List<Widget?> _pages = [
    ChatScreen(api: _api),
    null,
    null,
    null,
    null,
  ];

  static const _destinations = [
    NavigationDestination(
      key: ValueKey('nav-chat'),
      icon: Icon(Icons.chat_bubble_outline),
      label: 'Chat',
    ),
    NavigationDestination(
      key: ValueKey('nav-history'),
      icon: Icon(Icons.history),
      label: 'History',
    ),
    NavigationDestination(
      key: ValueKey('nav-memory'),
      icon: Icon(Icons.auto_awesome_outlined),
      label: 'Memory',
    ),
    NavigationDestination(
      key: ValueKey('nav-tools'),
      icon: Icon(Icons.build_outlined),
      label: 'Tools',
    ),
    NavigationDestination(
      key: ValueKey('nav-settings'),
      icon: Icon(Icons.settings_outlined),
      label: 'Settings',
    ),
  ];

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _index,
      children: List.generate(
        _pages.length,
        (index) => _pages[index] ?? const SizedBox.shrink(),
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _index,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: _destinations,
      onDestinationSelected: (index) {
        _pages[index] ??= switch (index) {
          1 => HistoryScreen(api: _api),
          2 => MemoryScreen(api: _api),
          3 => ToolsScreen(api: _api),
          4 => SettingsScreen(
            api: _api,
            config: widget.config,
            onSaveConfig: widget.onSaveConfig,
          ),
          _ => ChatScreen(api: _api),
        };
        setState(() => _index = index);
      },
    ),
  );
}
