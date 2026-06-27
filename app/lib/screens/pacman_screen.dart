import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class PacmanScreen extends StatefulWidget {
  const PacmanScreen({super.key});

  @override
  State<PacmanScreen> createState() => _PacmanScreenState();
}

class _PacmanScreenState extends State<PacmanScreen> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse('https://oshino.space/pacman'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0d0d0d),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111318),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Pac-Man',
            style: TextStyle(color: Colors.white, fontSize: 16)),
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}