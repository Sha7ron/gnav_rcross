import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class LauncherScreen extends StatelessWidget {
  const LauncherScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E21),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Accessibility Suite'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          children: [
            const SizedBox(height: 20),
            Text('Choose a Module',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 16,
                )),
            const SizedBox(height: 40),

            // ── Road Crossing ──
            _ModuleCard(
              icon: Icons.directions_walk,
              title: 'Road Crossing',
              subtitle: 'Unity training simulation for\nsafe road crossing practice',
              gradient: const [Color(0xFF1B5E20), Color(0xFF43A047)],
              shadowColor: Colors.green,
              onTap: () {
                HapticFeedback.mediumImpact();
                Navigator.pushNamed(context, '/unity');
              },
            ),
            const SizedBox(height: 24),

            // ── Head Tracking Controller ──
            _ModuleCard(
              icon: Icons.face,
              title: 'Head Gaze Controller',
              subtitle: 'Control your phone with head\nmovements + double-blink to select',
              gradient: const [Color(0xFF0D47A1), Color(0xFF29B6F6)],
              shadowColor: Colors.cyan,
              onTap: () {
                HapticFeedback.mediumImpact();
                Navigator.pushNamed(context, '/gaze');
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ModuleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final List<Color> gradient;
  final Color shadowColor;
  final VoidCallback onTap;

  const _ModuleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.gradient,
    required this.shadowColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [gradient[0].withOpacity(0.3), gradient[1].withOpacity(0.1)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: gradient[1].withOpacity(0.3)),
          boxShadow: [
            BoxShadow(
              color: shadowColor.withOpacity(0.15),
              blurRadius: 20,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: gradient),
              ),
              child: Icon(icon, color: Colors.white, size: 30),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      )),
                  const SizedBox(height: 6),
                  Text(subtitle,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 13,
                        height: 1.4,
                      )),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                color: Colors.white.withOpacity(0.3), size: 28),
          ],
        ),
      ),
    );
  }
}