// Identidad visual y animaciones compartidas: logo SIDFAM animado (mismo
// dibujo que app/static/logo.svg), fondo aurora, texto con brillo, botón con
// gradiente y entrada suave de tarjetas. Equivalen a app/static/fx.css del web.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';

bool _reduceMotion(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

// ======================================================================
// Logo
// ======================================================================

/// Logo SIDFAM. Con [intro] los párpados se dibujan al aparecer; con [animate]
/// el iris mira y parpadea y un destello recorre el ECG sin parar. La animación
/// continua gasta batería: úsala solo en pantallas breves (splash, login).
class SidfamLogo extends StatefulWidget {
  const SidfamLogo({super.key, this.size = 48, this.intro = false, this.animate = false});
  final double size;
  final bool intro;
  final bool animate;

  @override
  State<SidfamLogo> createState() => _SidfamLogoState();
}

class _SidfamLogoState extends State<SidfamLogo> with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
    value: widget.intro ? 0 : 1,
  );
  late final AnimationController _iris = AnimationController(vsync: this, duration: const Duration(seconds: 9));
  late final AnimationController _run = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion(context)) {
      _intro.value = 1;
      _iris.stop();
      _run.stop();
    } else {
      if (_intro.value < 1 && !_intro.isAnimating) _intro.forward();
      if (widget.animate && !_iris.isAnimating) _iris.repeat();
      if (widget.animate && !_run.isAnimating) _run.repeat();
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _iris.dispose();
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(
          painter: _LogoPainter(
            intro: _intro,
            iris: _iris,
            run: _run,
            still: !widget.animate || _reduceMotion(context),
          ),
        ),
      ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  _LogoPainter({required this.intro, required this.iris, required this.run, required this.still})
    : super(repaint: Listenable.merge([intro, iris, run]));

  final Animation<double> intro, iris, run;
  final bool still;

  static final Path _lid = Path()
    ..moveTo(84, 262)
    ..cubicTo(146, 148, 366, 148, 428, 262);
  static final Path _ecg = Path()
    ..moveTo(84, 262)
    ..cubicTo(112, 300, 150, 324, 190, 332)
    ..lineTo(224, 332)
    ..lineTo(242, 300)
    ..lineTo(260, 394)
    ..lineTo(280, 280)
    ..lineTo(296, 332)
    ..lineTo(322, 332)
    ..cubicTo(362, 324, 400, 300, 428, 262);

  static const _vis = [Color(0xFF22D3EE), Color(0xFF818CF8), Color(0xFFC084FC)];
  static const _pul = [Color(0xFF818CF8), Color(0xFFF472B6), Color(0xFFFB7185)];

  /// Tramo [a, b] (0..1) de un trazo.
  static Path _part(Path p, double a, double b) {
    final out = Path();
    for (final m in p.computeMetrics()) {
      out.addPath(m.extractPath(m.length * a.clamp(0.0, 1.0), m.length * b.clamp(0.0, 1.0)), Offset.zero);
    }
    return out;
  }

  static double _seg(double t, double a, double b) =>
      Curves.easeInOutCubic.transform(((t - a) / (b - a)).clamp(0.0, 1.0));

  /// Desplazamiento y escala vertical del iris (mira a los lados y parpadea).
  static (Offset, double) _irisPose(double t) {
    const keys = <(double, double, double)>[
      (0, 0, 0),
      (.18, -16, 2),
      (.38, 12, -4),
      (.48, 12, -4),
      (.70, 0, 0),
      (1, 0, 0),
    ];
    var o = Offset.zero;
    for (var i = 0; i < keys.length - 1; i++) {
      final (t0, x0, y0) = keys[i];
      final (t1, x1, y1) = keys[i + 1];
      if (t >= t0 && t <= t1) {
        final k = Curves.easeInOut.transform((t - t0) / (t1 - t0));
        o = Offset(x0 + (x1 - x0) * k, y0 + (y1 - y0) * k);
        break;
      }
    }
    final blink = t > .44 && t < .48 ? (1 - math.sin((t - .44) / .04 * math.pi) * .92) : 1.0;
    return (o, blink);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 512;
    canvas.save();
    canvas.scale(s);

    final t = intro.value;
    final box = RRect.fromRectAndRadius(const Rect.fromLTWH(8, 8, 496, 496), const Radius.circular(118));
    canvas.drawRRect(
      box,
      Paint()
        ..shader = ui.Gradient.linear(const Offset(8, 8), const Offset(504, 504), const [
          Color(0xFF0D1D40),
          Color(0xFF040814),
        ]),
    );
    canvas.drawRRect(
      box,
      Paint()..shader = ui.Gradient.radial(const Offset(157, 117), 372, const [Color(0x5938BDF8), Color(0x0038BDF8)]),
    );
    canvas.drawRRect(
      box.deflate(2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..shader = ui.Gradient.linear(
          const Offset(10, 10),
          const Offset(502, 502),
          const [Color(0xB37DD3FC), Color(0x26818CF8), Color(0x99C084FC)],
          const [0, .5, 1],
        ),
    );

    Paint stroke(List<Color> c, double w) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..shader = ui.Gradient.linear(const Offset(84, 0), const Offset(428, 0), c, const [0, .55, 1]);

    // iris, recortado donde lo cruza el ECG
    final popT = ((t - .5) / .35).clamp(0.0, 1.0);
    final pop = popT == 0 ? 0.0 : Curves.easeOutBack.transform(popT);
    if (pop > 0) {
      final (off, sy) = still ? (Offset.zero, 1.0) : _irisPose(iris.value);
      canvas.saveLayer(const Rect.fromLTWH(0, 0, 512, 512), Paint());
      canvas.save();
      canvas.translate(256 + off.dx, 236 + off.dy);
      canvas.scale(pop, pop * sy);
      canvas.drawCircle(
        Offset.zero,
        58,
        Paint()
          ..shader = ui.Gradient.radial(
            const Offset(-12, -17),
            81,
            const [Color(0xFF67E8F9), Color(0xFF6366F1), Color(0xFF4C1D95)],
            const [0, .6, 1],
          ),
      );
      canvas.drawCircle(
        Offset.zero,
        58,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..color = const Color(0x59A5F3FC),
      );
      canvas.drawCircle(Offset.zero, 24, Paint()..color = const Color(0xFF040814));
      canvas.drawCircle(const Offset(19, -19), 10, Paint()..color = Colors.white);
      canvas.restore();
      canvas.drawPath(
        _ecg,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 50
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..blendMode = BlendMode.clear,
      );
      canvas.restore();
    }

    final lidP = _seg(t, 0, .7);
    final ecgP = _seg(t, .22, .92);
    final halo = _seg(t, .7, 1) * .55;
    if (halo > 0) {
      final blur = MaskFilter.blur(BlurStyle.normal, 14);
      canvas.drawPath(
        _lid,
        stroke(_vis, 30)
          ..maskFilter = blur
          ..color = Colors.white.withValues(alpha: halo),
      );
      canvas.drawPath(
        _ecg,
        stroke(_pul, 30)
          ..maskFilter = blur
          ..color = Colors.white.withValues(alpha: halo),
      );
    }
    if (lidP > 0) canvas.drawPath(lidP >= 1 ? _lid : _part(_lid, 0, lidP), stroke(_vis, 28));
    if (ecgP > 0) canvas.drawPath(ecgP >= 1 ? _ecg : _part(_ecg, 0, ecgP), stroke(_pul, 26));

    // destello que recorre el ECG
    if (t >= 1 && !still) {
      final r = Curves.easeInOut.transform(run.value);
      final a = -0.08 + r * 1.13;
      canvas.drawPath(
        _part(_ecg, a, a + .08),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 12
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = Colors.white.withValues(alpha: .85),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LogoPainter old) => old.still != still;
}

// ======================================================================
// Fondo aurora
// ======================================================================

/// Manchas de color difusas detrás de toda la app. Es estática a propósito:
/// animarla redibujaba la pantalla completa a 60 fps y calentaba el teléfono.
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({super.key});

  @override
  Widget build(BuildContext context) => const RepaintBoundary(
    child: CustomPaint(painter: _AuroraPainter(), child: SizedBox.expand()),
  );
}

class _AuroraPainter extends CustomPainter {
  const _AuroraPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = C.bg);
    final m = size.longestSide;
    // mismas manchas que el panel web: lavanda, menta, lila y durazno
    final blobs = <(Offset, double, Color)>[
      (Offset(size.width * .06, size.height * .04), m * .62, const Color(0xBF8C82E1)),
      (Offset(size.width * .96, size.height * .08), m * .55, const Color(0xA678C8B2)),
      (Offset(size.width * .85, size.height * .95), m * .6, const Color(0xB3AA91E8)),
      (Offset(size.width * .1, size.height * .92), m * .5, const Color(0x8CF0BEAA)),
    ];
    for (final (c, r, col) in blobs) {
      canvas.drawCircle(c, r, Paint()..shader = ui.Gradient.radial(c, r, [col, col.withValues(alpha: 0)]));
    }
  }

  @override
  bool shouldRepaint(covariant _AuroraPainter old) => false;
}

// ======================================================================
// Texto con brillo, botón con gradiente y entrada suave
// ======================================================================

/// Texto con gradiente que se desplaza (como .fx-shine del web).
class ShimmerText extends StatefulWidget {
  const ShimmerText(this.text, {super.key, required this.style, this.textAlign, this.animate = true});
  final String text;
  final TextStyle style;
  final TextAlign? textAlign;

  /// false: gradiente fijo (para lo que queda siempre en pantalla, como la barra superior).
  final bool animate;

  @override
  State<ShimmerText> createState() => _ShimmerTextState();
}

class _ShimmerTextState extends State<ShimmerText> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 6));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.animate || _reduceMotion(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (r) {
          final dx = r.width * 2 * _c.value;
          return LinearGradient(
            colors: const [
              C.text,
              C.cyan,
              C.violeta,
              Color(0xFFC0609A),
              C.cyan,
              C.text,
            ],
            tileMode: TileMode.repeated,
          ).createShader(Rect.fromLTWH(-dx, 0, r.width * 2, r.height));
        },
        child: child,
      ),
      child: Text(widget.text, style: widget.style, textAlign: widget.textAlign),
    );
  }
}

/// Botón principal con el gradiente de la marca (cian → índigo → violeta).
class GradientButton extends StatelessWidget {
  const GradientButton({super.key, required this.onPressed, required this.child});
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: enabled ? 1 : .7,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: const LinearGradient(colors: [C.cyan, Color(0xFF8A86E0), C.violeta]),
          boxShadow: [
            BoxShadow(
              color: C.cyan.withValues(alpha: .45),
              blurRadius: 26,
              offset: const Offset(0, 10),
              spreadRadius: -8,
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              child: DefaultTextStyle.merge(
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
                child: IconTheme.merge(
                  data: const IconThemeData(color: Colors.white),
                  child: Center(child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Aparece subiendo y desvaneciéndose al montarse; [delay] escalona listas.
class FadeSlideIn extends StatelessWidget {
  const FadeSlideIn({super.key, required this.child, this.delay = Duration.zero, this.offset = 24});
  final Widget child;
  final Duration delay;
  final double offset;

  @override
  Widget build(BuildContext context) {
    if (_reduceMotion(context)) return child;
    const run = Duration(milliseconds: 650);
    final total = delay + run;
    final start = delay.inMilliseconds / total.inMilliseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, (1 - v) * offset), child: child),
      ),
      child: child,
    );
  }
}
