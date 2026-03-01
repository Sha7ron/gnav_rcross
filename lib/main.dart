import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'screens/launcher_screen.dart';
import 'screens/unity_game_screen.dart';
import 'screens/head_gaze_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const GazeNavApp());
}

class GazeNavApp extends StatelessWidget {
  const GazeNavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Accessibility Suite',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0E21),
        colorScheme: const ColorScheme.dark(
          primary: Colors.cyan,
          secondary: Colors.greenAccent,
        ),
      ),
      home: const _PermissionGate(),
      routes: {
        '/launcher': (_) => const LauncherScreen(),
        '/unity': (_) => const UnityGameScreen(),
        '/gaze': (_) => const HeadGazeScreen(),
      },
    );
  }
}

class _PermissionGate extends StatefulWidget {
  const _PermissionGate();

  @override
  State<_PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<_PermissionGate> {
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    final cam = await Permission.camera.status;
    if (!cam.isGranted) {
      await Permission.camera.request();
    }
    if (mounted) {
      setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return const LauncherScreen();
  }
}