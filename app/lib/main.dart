import 'package:flutter/material.dart';
import 'screens/login_screen.dart';

void main() {
  runApp(const OshinoApp());
}

class OshinoApp extends StatelessWidget {
  const OshinoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Oshino',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0d0d0d),
      ),
      home: const LoginScreen(),
    );
  }
}