import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../services/settings_service.dart';

// ── Perlin noise ─────────────────────────────────────────────────────────────
class _PerlinNoise {
  final List<int> _perm;
  _PerlinNoise(int seed) : _perm = _buildPerm(seed);

  static List<int> _buildPerm(int seed) {
    final rng = math.Random(seed);
    final p = List<int>.generate(256, (i) => i)..shuffle(rng);
    return [...p, ...p];
  }

  double _fade(double t) => t * t * t * (t * (t * 6 - 15) + 10);
  double _lerp(double a, double b, double t) => a + t * (b - a);

  double _grad(int hash, double x, double y) {
    switch (hash & 3) {
      case 0: return  x + y;
      case 1: return -x + y;
      case 2: return  x - y;
      case 3: return -x - y;
      default: return 0;
    }
  }

  double noise(double x, double y) {
    final xi = x.floor() & 255;
    final yi = y.floor() & 255;
    final xf = x - x.floor();
    final yf = y - y.floor();
    final u = _fade(xf);
    final v = _fade(yf);
    final aa = _perm[_perm[xi] + yi];
    final ab = _perm[_perm[xi] + yi + 1];
    final ba = _perm[_perm[xi + 1] + yi];
    final bb = _perm[_perm[xi + 1] + yi + 1];
    return _lerp(
      _lerp(_grad(aa, xf, yf), _grad(ba, xf - 1, yf), u),
      _lerp(_grad(ab, xf, yf - 1), _grad(bb, xf - 1, yf - 1), u),
      v,
    );
  }
}

// ── Частица ──────────────────────────────────────────────────────────────────
class _Particle {
  double x, y, lx, ly, vx = 0, vy = 0, ax = 0, ay = 0;
  final double hueSeed;
  late double hue, sat, light, maxSpeed;
  final List<Offset> trail = [];
  static const int maxTrail = 20;

  _Particle(this.x, this.y, this.hueSeed) : lx = x, ly = y;

  void applyOpt({
    required double h1, required double h2,
    required double s1, required double s2,
    required double l1, required double l2,
  }) {
    hue      = hueSeed > .5 ? 20 + h1 : 20 + h2;
    sat      = hueSeed > .5 ? s1 : s2;
    light    = hueSeed > .5 ? l1 : l2;
    maxSpeed = hueSeed > .5 ? 1.2 : 0.8;
  }

  void update(_PerlinNoise noise, double noiseScale, double angle, double time,
      double w, double h) {
final a = noise.noise(x * noiseScale, y * noiseScale + time * noiseScale)
        * math.pi * 0.4 + angle;
    ax += math.cos(a);
    ay += math.sin(a);
    vx += ax; vy += ay;
    final speed = math.sqrt(vx * vx + vy * vy);
    final ang = math.atan2(vy, vx);
    final m = math.min(maxSpeed, speed);
    vx = math.cos(ang) * m;
    vy = math.sin(ang) * m;

    trail.add(Offset(x, y));
    if (trail.length > maxTrail) trail.removeAt(0);

    x += vx; y += vy;
    ax = 0; ay = 0;

    if (x < 0 || x > w || y < 0 || y > h) {
      final rng = math.Random();
      x = rng.nextDouble() * w;
      y = rng.nextDouble() * h;
      lx = x; ly = y;
      vx = 0; vy = 0;
      trail.clear();
    }
  }
}

// ── Painter ──────────────────────────────────────────────────────────────────
class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final double time;

  _ParticlePainter({required this.particles, required this.time});

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      if (p.trail.length < 2) continue;
      for (int i = 1; i < p.trail.length; i++) {
        final alpha = (i / p.trail.length) * 0.6;
        final paint = Paint()
          ..color = HSLColor.fromAHSL(
            alpha,
            p.hue % 360,
            (p.sat / 100).clamp(0.0, 1.0),
            (p.light / 100).clamp(0.0, 1.0),
          ).toColor()
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(p.trail[i - 1], p.trail[i], paint);
      }
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) => old.time != time;
}

// ── Widget ───────────────────────────────────────────────────────────────────
class ParticleBackground extends StatefulWidget {
  final bool darkTheme;
  const ParticleBackground({super.key, this.darkTheme = true});

  @override
  State<ParticleBackground> createState() => _ParticleBackgroundState();
}

class _ParticleBackgroundState extends State<ParticleBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late _PerlinNoise _noise;
  double _angle = -math.pi / 2;
  List<_Particle> _particles = [];
  double _time = 0;
  Size _lastSize = Size.zero;

  static const int _count = 50;
  static const double _noiseScale = 0.005;

  @override
  void initState() {
    super.initState();
    _noise = _PerlinNoise(DateTime.now().millisecondsSinceEpoch);
    final directions = [
      -math.pi / 2, // вверх
       math.pi / 2, // вниз
       math.pi,     // влево
       0.0,         // вправо
    ];
    _angle = directions[math.Random().nextInt(4)];
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 16),
    )..addListener(_tick)..repeat();
  }

  void _initParticles(Size size) {
    final rng = math.Random();
    _particles = List.generate(_count, (_) {
      final p = _Particle(
        rng.nextDouble() * size.width,
        rng.nextDouble() * size.height,
        rng.nextDouble(),
      );
      p.applyOpt(h1: 200, h2: 220, s1: 60, s2: 50, l1: 50, l2: 45);
      return p;
    });
  }

  void _tick() {
    if (_particles.isEmpty) return;
    _time += 0.75;
    final w = _lastSize.width;
    final h = _lastSize.height;
    for (final p in _particles) {
      p.update(_noise, _noiseScale, _angle, _time, w, h);
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      if (size.width > 0 && size != _lastSize) {
        _lastSize = size;
        _initParticles(size);
      }
      return Container(
        color: const Color(0xFF0d0d0d),
        child: CustomPaint(
          size: size,
          painter: _ParticlePainter(
            particles: _particles,
            time: _time,
          ),
        ),
      );
    });
  }
}
// ── Фон приложения с учётом настройки анимации ───────────────────────────────
/// Реактивная обёртка: показывает анимированные частицы, когда
/// SettingsService.instance.bgAnim == true, иначе — однотонную заливку.
/// Когда анимация выключена, ParticleBackground не строится вовсе
/// (контроллер анимации не работает — экономия батареи).
class OshinoBackground extends StatelessWidget {
  const OshinoBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: SettingsService.instance.bgAnim,
      builder: (context, on, _) {
        if (on) {
          return const ParticleBackground(darkTheme: true);
        }
        return Container(color: const Color(0xFF0d0d0d));
      },
    );
  }
}
