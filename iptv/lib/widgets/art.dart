import 'package:flutter/material.dart';

/// رسم موجات بث ونقاط خفيفة تُستخدم كخلفية للّافتات
class WavesPainter extends CustomPainter {
  final Color color;
  const WavesPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width * 0.9, size.height * 0.5);
    for (var i = 1; i <= 5; i++) {
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..color = color.withAlpha((90 - i * 14).clamp(8, 90).toInt());
      canvas.drawCircle(c, 18.0 + i * 24, p);
    }
    final dot = Paint()..color = color.withAlpha(120);
    const spots = [Offset(.10, .24), Offset(.27, .74), Offset(.46, .20), Offset(.58, .80), Offset(.37, .48)];
    for (final d in spots) {
      canvas.drawCircle(Offset(size.width * d.dx, size.height * d.dy), 1.6, dot);
    }
  }

  @override
  bool shouldRepaint(covariant WavesPainter old) => old.color != color;
}

/// لافتة بخلفية متدرجة مع موجات بث
class ArtBanner extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final List<Color> colors;
  final double radius;
  const ArtBanner({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.colors = const [Color(0xFF123D70), Color(0xFF0B1424)],
    this.radius = 17,
  });

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
          ),
          child: Stack(children: [
            const Positioned.fill(child: CustomPaint(painter: WavesPainter(Color(0xFF75BDFF)))),
            Padding(padding: padding, child: child),
          ]),
        ),
      );
}

/// أيقونة داخل مربع متدرج
Widget gradientBadge(IconData icon, List<Color> colors, {double size = 38}) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.5),
    );

const List<Color> kBlueGrad = [Color(0xFF2F9BFF), Color(0xFF1558B0)];
const List<Color> kTealGrad = [Color(0xFF22C7D6), Color(0xFF0B6E7A)];
const List<Color> kGreenGrad = [Color(0xFF34D399), Color(0xFF12794F)];
