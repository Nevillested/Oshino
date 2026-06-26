import 'package:flutter/material.dart';

class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0d0d0d),
      body: Center(
        child: Text(
          'Main Screen',
          style: TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}