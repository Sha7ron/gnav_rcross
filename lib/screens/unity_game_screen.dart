/// ===========================================================================
/// Unity Game Screen - Launches Unity game as separate app via Intent
/// ===========================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class UnityGameScreen extends StatefulWidget {
  const UnityGameScreen({super.key});

  @override
  State<UnityGameScreen> createState() => _UnityGameScreenState();
}

class _UnityGameScreenState extends State<UnityGameScreen> {
  static const _channel = MethodChannel('com.gazenav/unity');
  bool _launching = false;
  bool _notInstalled = false;

  Future<void> _launchUnity() async {
    setState(() { _launching = true; _notInstalled = false; });
    try {
      final result = await _channel.invokeMethod('launchUnity');
      if (result == false) {
        setState(() => _notInstalled = true);
      }
    } on PlatformException catch (e) {
      setState(() => _notInstalled = true);
    } on MissingPluginException {
      setState(() => _notInstalled = true);
    }
    setState(() => _launching = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E21),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Road Crossing Training'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 120, height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1B5E20), Color(0xFF43A047)],
                  ),
                  boxShadow: [
                    BoxShadow(color: Colors.green.withOpacity(0.3), blurRadius: 30, spreadRadius: 5),
                  ],
                ),
                child: const Icon(Icons.directions_walk, size: 56, color: Colors.white),
              ),
              const SizedBox(height: 36),
              const Text('Road Crossing Training',
                  style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text(
                'A Unity-based training simulation to help\nchildren with autism practice safe road crossing.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 14, height: 1.5),
              ),
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity, height: 56,
                child: ElevatedButton.icon(
                  onPressed: _launching ? null : _launchUnity,
                  icon: _launching
                      ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : const Icon(Icons.play_arrow, size: 28),
                  label: Text(_launching ? 'Launching...' : 'Start Training',
                      style: const TextStyle(fontSize: 18)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.greenAccent,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    elevation: 8,
                    shadowColor: Colors.greenAccent.withOpacity(0.3),
                  ),
                ),
              ),
              if (_notInstalled) ...[
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.orange.withOpacity(0.3)),
                  ),
                  child: Column(children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
                    const SizedBox(height: 8),
                    const Text('Game Not Installed',
                        style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 8),
                    Text(
                      'The Road Crossing Training app needs to be\n'
                          'installed separately on this device.\n\n'
                          'Build the Unity project as an APK and install it.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12, height: 1.5),
                    ),
                  ]),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}