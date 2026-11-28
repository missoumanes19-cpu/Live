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
  final List<Color>? colors;
  final double radius;
  const ArtBanner({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.colors,
    this.radius = 17,
  });

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: colors ?? kBannerGrad, begin: Alignment.topLeft, end: Alignment.bottomRight),
          ),
          child: Stack(children: [
            Positioned.fill(child: CustomPaint(painter: WavesPainter(kWave))),
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

/// لوحة ألوان متناسقة يختارها المستخدم من الإعدادات
class AppPalette {
  final String id, label;
  final Color accent, accent2, accent3, wave, selBg, swatch;
  final List<Color> banner, g1, g2, g3;
  const AppPalette(this.id, this.label, this.accent, this.accent2, this.accent3, this.wave, this.selBg,
      this.banner, this.g1, this.g2, this.g3) : swatch = accent;
}

const List<AppPalette> kPalettes = [
  AppPalette('gold', 'ذهبي', Color(0xFFF5B301), Color(0xFFFFC933), Color(0xFFFFD66B), Color(0xFFFFD66B), Color(0xFF3A2C08),
      [Color(0xFF3D2E05), Color(0xFF120E04)],
      [Color(0xFFF5B301), Color(0xFFB07A00)], [Color(0xFFFFCF4D), Color(0xFFC98A00)], [Color(0xFFD99A00), Color(0xFF7A5500)]),
  AppPalette('blue', 'أزرق', Color(0xFF168BFF), Color(0xFF42A5FF), Color(0xFF62B2FF), Color(0xFF75BDFF), Color(0xFF123C70),
      [Color(0xFF123D70), Color(0xFF0B1424)],
      [Color(0xFF2F9BFF), Color(0xFF1558B0)], [Color(0xFF22C7D6), Color(0xFF0B6E7A)], [Color(0xFF34D399), Color(0xFF12794F)]),
  AppPalette('green', 'أخضر', Color(0xFF19B37A), Color(0xFF34D399), Color(0xFF6EE7B7), Color(0xFF6EE7B7), Color(0xFF0E3F30),
      [Color(0xFF0F4A38), Color(0xFF08130F)],
      [Color(0xFF34D399), Color(0xFF12794F)], [Color(0xFF2DD4BF), Color(0xFF0F766E)], [Color(0xFF86EFAC), Color(0xFF15803D)]),
  AppPalette('red', 'أحمر', Color(0xFFE5484D), Color(0xFFFF6B6F), Color(0xFFFF9A9D), Color(0xFFFF9A9D), Color(0xFF4A1417),
      [Color(0xFF5A1519), Color(0xFF140808)],
      [Color(0xFFFF6B6F), Color(0xFFB3262B)], [Color(0xFFFF8A8A), Color(0xFFC0353A)], [Color(0xFFD9484D), Color(0xFF7A1E22)]),
  AppPalette('purple', 'بنفسجي', Color(0xFF8B5CF6), Color(0xFFA78BFA), Color(0xFFC4B5FD), Color(0xFFC4B5FD), Color(0xFF33236B),
      [Color(0xFF3B2A7A), Color(0xFF110B24)],
      [Color(0xFFA78BFA), Color(0xFF6D28D9)], [Color(0xFFC084FC), Color(0xFF7E22CE)], [Color(0xFF818CF8), Color(0xFF4338CA)]),
];

// قيم حالية (تتغير عند اختيار لوحة جديدة)
Color kAccent = const Color(0xFFF5B301);
Color kAccent2 = const Color(0xFFFFC933);
Color kAccent3 = const Color(0xFFFFD66B);
Color kWave = const Color(0xFFFFD66B);
Color kSelBg = const Color(0xFF3A2C08);
List<Color> kBannerGrad = const [Color(0xFF3D2E05), Color(0xFF120E04)];
List<Color> kBlueGrad = const [Color(0xFFF5B301), Color(0xFFB07A00)];
List<Color> kTealGrad = const [Color(0xFFFFCF4D), Color(0xFFC98A00)];
List<Color> kGreenGrad = const [Color(0xFFD99A00), Color(0xFF7A5500)];

void applyPalette(String id) {
  final p = kPalettes.firstWhere((e) => e.id == id, orElse: () => kPalettes.first);
  kAccent = p.accent; kAccent2 = p.accent2; kAccent3 = p.accent3; kWave = p.wave; kSelBg = p.selBg;
  kBannerGrad = p.banner; kBlueGrad = p.g1; kTealGrad = p.g2; kGreenGrad = p.g3;
}

/// يعيد بناء كل العناصر الحالية مع الحفاظ على حالتها (لتظهر الألوان الجديدة فوراً)
void rebuildAllElements() {
  void visit(Element e) { e.markNeedsBuild(); e.visitChildren(visit); }
  WidgetsBinding.instance.rootElement?.visitChildren(visit);
}
