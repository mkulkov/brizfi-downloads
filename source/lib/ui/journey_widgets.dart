import 'package:flutter/material.dart';

/// Four locally bundled illustrations; no network image requests.
class JourneyIllustration extends StatelessWidget {
  const JourneyIllustration(this.index, {super.key});
  final int index;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.clamp(0.0, 400.0);
        return Center(
          child: SizedBox(
            width: width,
            // Keep the artwork equally sized across stages and banner states.
            height: (width * .55).clamp(0.0, 140.0),
            child: Image.asset(
              'assets/illustrations/journey-$index.png',
              fit: BoxFit.contain,
              excludeFromSemantics: true,
            ),
          ),
        );
      },
    ),
  );
}

enum PaperKind { label, ticket, receipt, tag }

class PaperShape extends RoundedRectangleBorder {
  const PaperShape(this.kind, {super.side})
    : super(borderRadius: const BorderRadius.all(Radius.circular(12)));
  final PaperKind kind;

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width == 0) return;
    canvas.drawPath(
      getOuterPath(rect.deflate(side.width / 2), textDirection: textDirection),
      side.toPaint(),
    );
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(12)));
    if (kind == PaperKind.ticket) {
      final cuts = Path()
        ..addOval(Rect.fromCircle(center: rect.centerLeft, radius: 7))
        ..addOval(Rect.fromCircle(center: rect.centerRight, radius: 7));
      return Path.combine(PathOperation.difference, path, cuts);
    }
    if (kind == PaperKind.label) {
      final cut = Path()
        ..moveTo(rect.right - 17, rect.top)
        ..lineTo(rect.right, rect.top + 17)
        ..lineTo(rect.right, rect.top)
        ..close();
      return Path.combine(PathOperation.difference, path, cut);
    }
    if (kind == PaperKind.receipt) {
      final cuts = Path();
      for (var x = rect.left + 8; x < rect.right; x += 16) {
        cuts.addOval(
          Rect.fromCircle(center: Offset(x, rect.bottom), radius: 4),
        );
      }
      return Path.combine(PathOperation.difference, path, cuts);
    }
    if (kind == PaperKind.tag) {
      final tag = Path()
        ..moveTo(rect.left, rect.center.dy)
        ..lineTo(rect.left + 20, rect.top)
        ..lineTo(rect.right - 10, rect.top)
        ..quadraticBezierTo(rect.right, rect.top, rect.right, rect.top + 10)
        ..lineTo(rect.right, rect.bottom - 10)
        ..quadraticBezierTo(
          rect.right,
          rect.bottom,
          rect.right - 10,
          rect.bottom,
        )
        ..lineTo(rect.left + 20, rect.bottom)
        ..close();
      return Path.combine(
        PathOperation.difference,
        tag,
        Path()..addOval(
          Rect.fromCircle(
            center: Offset(rect.left + 16, rect.center.dy),
            radius: 3,
          ),
        ),
      );
    }
    return path;
  }

  @override
  PaperShape copyWith({BorderSide? side, BorderRadiusGeometry? borderRadius}) =>
      PaperShape(kind, side: side ?? this.side);
}

class ParcelButton extends StatelessWidget {
  const ParcelButton({required this.label, required this.onPressed, super.key});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          style: FilledButton.styleFrom(
            shape: const PaperShape(PaperKind.label),
          ),
          onPressed: onPressed,
          child: Row(
            children: [
              Expanded(child: Text(label, textAlign: TextAlign.center)),
              const SizedBox(width: 8),
              const ExcludeSemantics(child: Icon(Icons.arrow_forward_rounded)),
            ],
          ),
        ),
      ),
      const Positioned(
        right: 2,
        top: 2,
        child: IgnorePointer(
          child: ExcludeSemantics(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CustomPaint(painter: _FoldPainter()),
            ),
          ),
        ),
      ),
    ],
  );
}

class _FoldPainter extends CustomPainter {
  const _FoldPainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(0, size.height)
        ..lineTo(size.width, size.height)
        ..close(),
      Paint()..color = const Color(0xFFEEA264),
    );
  }

  @override
  bool shouldRepaint(_FoldPainter oldDelegate) => false;
}

class ConnectionTicket extends StatelessWidget {
  const ConnectionTicket({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
    super.key,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          backgroundColor: selected
              ? c.primary.withValues(alpha: .08)
              : c.surface,
          shape: const PaperShape(PaperKind.ticket),
          side: BorderSide(
            color: selected ? c.secondary : c.outline,
            width: selected ? 2 : 1,
          ),
        ),
        onPressed: onPressed,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Icon(
                selected ? Icons.check_circle_outline : icon,
                size: 24,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(child: Text(label, textAlign: TextAlign.center)),
          ],
        ),
      ),
    );
  }
}

class PaperReceipt extends StatelessWidget {
  const PaperReceipt({required this.child, super.key});
  final Widget child;
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    shape: const PaperShape(PaperKind.receipt),
    child: Padding(padding: const EdgeInsets.all(20), child: child),
  );
}

class PaperDivider extends StatelessWidget {
  const PaperDivider({super.key});
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 12,
    width: double.infinity,
    child: CustomPaint(
      painter: _DashPainter(Theme.of(context).colorScheme.outlineVariant),
    ),
  );
}

class _DashPainter extends CustomPainter {
  _DashPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 8) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset((x + 4).clamp(0, size.width), size.height / 2),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_DashPainter oldDelegate) => color != oldDelegate.color;
}
