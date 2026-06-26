import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../services/api_service.dart';
import 'main_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with TickerProviderStateMixin {
  final _loginController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  bool _obscurePassword = true;
  String? _error;

  late AnimationController _wave1Controller;
  late AnimationController _wave2Controller;
  late AnimationController _wave3Controller;

  @override
  void initState() {
    super.initState();
    _wave1Controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
    _wave2Controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 9),
    )..repeat(reverse: true);
    _wave3Controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _wave1Controller.dispose();
    _wave2Controller.dispose();
    _wave3Controller.dispose();
    _loginController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final result = await ApiService.login(
      _loginController.text.trim(),
      _passwordController.text,
    );

    if (!mounted) return;

    if (result == null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainScreen()),
      );
    } else {
      setState(() {
        _error = result;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0f1117),
      body: Stack(
        children: [
          // Волны внизу
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: 300,
            child: Stack(
              children: [
                AnimatedBuilder(
                  animation: _wave1Controller,
                  builder: (_, __) => CustomPaint(
                    size: Size(MediaQuery.of(context).size.width, 300),
                    painter: _WavePainter(
                      offset: _wave1Controller.value,
                      color: const Color(0xFF1a2240),
                      path: WavePath.wave1,
                    ),
                  ),
                ),
                AnimatedBuilder(
                  animation: _wave2Controller,
                  builder: (_, __) => CustomPaint(
                    size: Size(MediaQuery.of(context).size.width, 300),
                    painter: _WavePainter(
                      offset: _wave2Controller.value,
                      color: const Color(0xFF0d1830).withOpacity(0.85),
                      path: WavePath.wave2,
                    ),
                  ),
                ),
                AnimatedBuilder(
                  animation: _wave3Controller,
                  builder: (_, __) => CustomPaint(
                    size: Size(MediaQuery.of(context).size.width, 300),
                    painter: _WavePainter(
                      offset: _wave3Controller.value,
                      color: const Color(0xFF4a90e2).withOpacity(0.12),
                      path: WavePath.wave3,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Форма
          Center(
            child: Transform.translate(
              offset: Offset(0, -MediaQuery.of(context).size.height * 0.06),
              child: SizedBox(
                width: 300,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'Oshino',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 40),

                    // Логин
                    TextField(
                      controller: _loginController,
                      decoration: InputDecoration(
                        hintText: 'Логин',
                        filled: true,
                        fillColor: const Color(0xFF1a1d26),
                        hintStyle: const TextStyle(color: Color(0xFF3a3f52)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 13),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                              color: Color(0xFF2a2d3a)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                              color: Color(0xFF2a2d3a)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                              color: Color(0xFF4a90e2), width: 1.5),
                        ),
                      ),
                      style: const TextStyle(
                          color: Color(0xFFe0e4f0), fontSize: 15),
                      onSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 16),

                    // Пароль с глазиком
                    TextField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      decoration: InputDecoration(
                        hintText: 'Пароль',
                        filled: true,
                        fillColor: const Color(0xFF1a1d26),
                        hintStyle: const TextStyle(color: Color(0xFF3a3f52)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 13),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                              color: Color(0xFF2a2d3a)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                              color: Color(0xFF2a2d3a)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                              color: Color(0xFF4a90e2), width: 1.5),
                        ),
                        suffixIcon: GestureDetector(
                          onTap: () => setState(
                              () => _obscurePassword = !_obscurePassword),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: CustomPaint(
                              size: const Size(20, 20),
                              painter: _EyePainter(
                                  closed: _obscurePassword),
                            ),
                          ),
                        ),
                      ),
                      style: const TextStyle(
                          color: Color(0xFFe0e4f0), fontSize: 15),
                      onSubmitted: (_) => _submit(),
                    ),

                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: const TextStyle(
                            color: Color(0xFFe05555), fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 16),

                    // Кнопка
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _loading ? null : _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4a90e2),
                          padding:
                              const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          elevation: 0,
                        ),
                        child: _loading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text(
                                'Войти',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.5,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Волны ────────────────────────────────────────────────────────────────────

enum WavePath { wave1, wave2, wave3 }

class _WavePainter extends CustomPainter {
  final double offset;
  final Color color;
  final WavePath path;

  _WavePainter({
    required this.offset,
    required this.color,
    required this.path,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final w = size.width;
    final h = size.height;

    // Сдвигаем на -offset*w (один период = ширина экрана)
    final dx = -offset * w;

    final p = Path();

    switch (this.path) {
      case WavePath.wave1:
        // M0,180 C240,280 480,80 720,180 C960,280 1200,80 1440,180 (2 периода)
        final y1 = h * 0.60;
        final yHigh = h * 0.267;
        final yLow = h * 0.933;
        p.moveTo(dx, y1);
        for (int i = 0; i < 3; i++) {
          final x = dx + i * w;
          p.cubicTo(
            x + w * 0.167, yLow,
            x + w * 0.333, yHigh,
            x + w * 0.5, y1,
          );
          p.cubicTo(
            x + w * 0.667, yLow,
            x + w * 0.833, yHigh,
            x + w, y1,
          );
        }
        p.lineTo(dx + 3 * w, h);
        p.lineTo(dx, h);
        break;

      case WavePath.wave2:
        final y2 = h * 0.667;
        final yHigh2 = h * 0.333;
        final yLow2 = h * 0.967;
        p.moveTo(dx, y2);
        for (int i = 0; i < 3; i++) {
          final x = dx + i * w;
          p.cubicTo(
            x + w * 0.167, yHigh2,
            x + w * 0.333, yLow2,
            x + w * 0.5, y2,
          );
          p.cubicTo(
            x + w * 0.667, yHigh2,
            x + w * 0.833, yLow2,
            x + w, y2,
          );
        }
        p.lineTo(dx + 3 * w, h);
        p.lineTo(dx, h);
        break;

      case WavePath.wave3:
        final y3 = h * 0.767;
        final yHigh3 = h * 0.467;
        p.moveTo(dx, y3);
        for (int i = 0; i < 3; i++) {
          final x = dx + i * w;
          p.cubicTo(
            x + w * 0.25, yHigh3,
            x + w * 0.5, h,
            x + w * 0.75, y3,
          );
          p.cubicTo(
            x + w * 0.875, h * 0.533,
            x + w, y3,
            x + w, y3,
          );
        }
        p.lineTo(dx + 3 * w, h);
        p.lineTo(dx, h);
        break;
    }
    p.close();
    canvas.drawPath(p, paint);
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.offset != offset;
}

// ── Глазик ───────────────────────────────────────────────────────────────────

class _EyePainter extends CustomPainter {
  final bool closed;
  const _EyePainter({required this.closed});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF4a4f65)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final w = size.width;
    final h = size.height;

    // Верхняя дуга
    final topPath = Path();
    topPath.moveTo(0, h * 0.5);
    topPath.quadraticBezierTo(
      w * 0.5, closed ? h * 0.4 : 0,
      w, h * 0.5,
    );
    canvas.drawPath(topPath, paint);

    // Нижняя дуга
    final botPath = Path();
    botPath.moveTo(0, h * 0.5);
    botPath.quadraticBezierTo(
      w * 0.5, closed ? h * 0.6 : h,
      w, h * 0.5,
    );
    canvas.drawPath(botPath, paint);

    // Зрачок (только когда открыт)
    if (!closed) {
      canvas.drawCircle(
        Offset(w * 0.5, h * 0.5),
        w * 0.22,
        Paint()..color = const Color(0xFF4a4f65),
      );
    } else {
      // Черта когда закрыт
      canvas.drawLine(
        Offset(w * 0.1, h * 0.5),
        Offset(w * 0.9, h * 0.5),
        paint,git add app/lib/
      );
    }
  }

  @override
  bool shouldRepaint(_EyePainter old) => old.closed != closed;
}