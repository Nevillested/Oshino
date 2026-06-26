import 'package:flutter/material.dart';
import '../widgets/particle_bg.dart';

class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0d0d0d),
      body: Stack(
        children: [
          const Positioned.fill(
            child: ParticleBackground(darkTheme: true),
          ),
          const Center(
            child: Text(
              'Main Screen',
              style: TextStyle(color: Colors.white, fontSize: 24),
            ),
          ),
        ],
      ),
    );
  }
}