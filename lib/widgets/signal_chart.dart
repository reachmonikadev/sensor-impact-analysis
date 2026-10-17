import 'dart:math' as math;

import 'package:flutter/material.dart';

class ChartSeries {
  const ChartSeries(this.label, this.color, this.values);
  final String label;
  final Color color;
  final List<double> values;
}

/// Lightweight scrolling line chart (no external chart dependency).
class SignalChart extends StatelessWidget {
  const SignalChart({
    super.key,
    required this.series,
    required this.capacity,
    this.minY,
    this.maxY,
    this.threshold,
    this.unit = 'g',
    this.height = 180,
  });

  final List<ChartSeries> series;
  final int capacity;
  final double? minY, maxY;
  final double? threshold;
  final String unit;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _ChartPainter(
              series: series,
              capacity: capacity,
              minY: minY,
              maxY: maxY,
              threshold: threshold,
              unit: unit,
              grid: scheme.outlineVariant,
              text: scheme.onSurfaceVariant,
              thresholdColor: scheme.error,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 16,
          children: [
            for (final s in series)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 12, height: 3, color: s.color),
                const SizedBox(width: 4),
                Text(s.label, style: Theme.of(context).textTheme.labelSmall),
              ]),
          ],
        ),
      ],
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.series,
    required this.capacity,
    required this.minY,
    required this.maxY,
    required this.threshold,
    required this.unit,
    required this.grid,
    required this.text,
    required this.thresholdColor,
  });

  final List<ChartSeries> series;
  final int capacity;
  final double? minY, maxY, threshold;
  final String unit;
  final Color grid, text, thresholdColor;

  @override
  void paint(Canvas canvas, Size size) {
    var lo = minY ?? double.infinity, hi = maxY ?? -double.infinity;
    for (final s in series) {
      for (final v in s.values) {
        if (minY == null) lo = math.min(lo, v);
        if (maxY == null) hi = math.max(hi, v);
      }
    }
    if (threshold != null) hi = math.max(hi, threshold! * 1.2);
    if (!lo.isFinite || !hi.isFinite) {
      lo = -1;
      hi = 1;
    }
    if (hi - lo < 0.5) {
      final mid = (hi + lo) / 2;
      lo = mid - 0.25;
      hi = mid + 0.25;
    }

    const left = 36.0;
    final plot = Rect.fromLTWH(left, 4, size.width - left, size.height - 8);
    double y(double v) => plot.bottom - (v - lo) / (hi - lo) * plot.height;

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final v = lo + (hi - lo) * i / 4;
      final py = y(v);
      canvas.drawLine(Offset(plot.left, py), Offset(plot.right, py), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: v.toStringAsFixed(1), style: TextStyle(color: text, fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, py - tp.height / 2));
    }

    if (threshold != null) {
      final py = y(threshold!);
      final p = Paint()
        ..color = thresholdColor
        ..strokeWidth = 1.5;
      for (var x = plot.left; x < plot.right; x += 8) {
        canvas.drawLine(Offset(x, py), Offset(math.min(x + 4, plot.right), py), p);
      }
    }

    canvas.save();
    canvas.clipRect(plot);
    final dx = plot.width / math.max(1, capacity - 1);
    for (final s in series) {
      if (s.values.length < 2) continue;
      final path = Path();
      final offset = capacity - s.values.length;
      for (var i = 0; i < s.values.length; i++) {
        final pt = Offset(plot.left + (offset + i) * dx, y(s.values[i]));
        i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = s.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeJoin = StrokeJoin.round,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => true;
}
