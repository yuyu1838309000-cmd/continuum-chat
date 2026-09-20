import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'services/server_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final config = await ServerConfig.load(preferences);
  runApp(ContinuumApp(initialConfig: config, preferences: preferences));
}
