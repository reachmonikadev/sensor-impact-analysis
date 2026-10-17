import 'dart:math' as math;

import 'protocol.dart';

enum ImpactSeverity { light, moderate, severe }

enum MotionEventKind { impact, freeFall }

/// A detected impact (or free fall, which typically precedes a drop impact).
class MotionEvent {
  MotionEvent({
    required this.kind,
    required this.time,
    required this.peakG,
    required this.duration,
    required this.direction,
    this.saturated = false,
  });

  final MotionEventKind kind;
  final DateTime time;

  /// Peak dynamic (gravity-removed) acceleration in g. For free fall this is
  /// the minimum total acceleration seen.
  final double peakG;
  final Duration duration;

  /// Unit vector of the dynamic acceleration at the peak, sensor frame.
  final List<double> direction;

  /// The sensor clipped at ±16 g; the true peak was higher.
  final bool saturated;

  ImpactSeverity get severity {
    if (peakG >= 8) return ImpactSeverity.severe;
    if (peakG >= 4) return ImpactSeverity.moderate;
    return ImpactSeverity.light;
  }

  /// Dominant axis of the hit, e.g. "+X" or "-Z".
  String get dominantAxis {
    var best = 0;
    for (var i = 1; i < 3; i++) {
      if (direction[i].abs() > direction[best].abs()) best = i;
    }
    final sign = direction[best] >= 0 ? '+' : '-';
    return '$sign${'XYZ'[best]}';
  }
}

/// Detects impacts from a stream of accelerometer samples.
///
/// Gravity is tracked with a slow low-pass filter and subtracted, so the
/// detector reacts to the *dynamic* acceleration regardless of how the
/// sensor is mounted. An impact starts when the dynamic magnitude crosses
/// [thresholdG], its peak is tracked until the signal falls back below half
/// the threshold, and a refractory period suppresses ringing after the hit.
class ImpactDetector {
  ImpactDetector({
    this.thresholdG = 2.0,
    this.gravityTimeConstant = const Duration(milliseconds: 600),
    this.refractory = const Duration(milliseconds: 300),
    this.maxImpactDuration = const Duration(milliseconds: 500),
    this.freeFallG = 0.35,
    this.freeFallMin = const Duration(milliseconds: 120),
  });

  double thresholdG;
  final Duration gravityTimeConstant;
  final Duration refractory;
  final Duration maxImpactDuration;
  final double freeFallG;
  final Duration freeFallMin;

  List<double>? _gravity;
  DateTime? _lastTime;

  // in-progress impact
  DateTime? _impactStart;
  double _peak = 0;
  List<double> _peakVec = const [0, 0, 0];
  bool _peakSaturated = false;
  DateTime? _refractoryUntil;

  // in-progress free fall
  DateTime? _fallStart;
  double _fallMin = 1;
  bool _fallReported = false;

  /// Latest dynamic acceleration magnitude in g (for charts).
  double lastDynamicG = 0;

  /// Latest total acceleration magnitude in g.
  double lastTotalG = 1;

  void reset() {
    _gravity = null;
    _lastTime = null;
    _impactStart = null;
    _refractoryUntil = null;
    _fallStart = null;
    _peak = 0;
  }

  /// Processes one sample; returns any events that completed on it.
  List<MotionEvent> add(ImuSample s) {
    final events = <MotionEvent>[];
    final a = [s.ax, s.ay, s.az];
    final total = _norm(a);
    lastTotalG = total;

    final g = _gravity ??= List.of(a);
    final dyn = [a[0] - g[0], a[1] - g[1], a[2] - g[2]];
    final dynMag = _norm(dyn);
    lastDynamicG = dynMag;

    final inImpact = _impactStart != null;
    // Only learn gravity while things are calm so a hit doesn't skew it.
    if (!inImpact && dynMag < thresholdG * 0.5 && _lastTime != null) {
      final dt = s.time.difference(_lastTime!).inMicroseconds / 1e6;
      final tau = gravityTimeConstant.inMicroseconds / 1e6;
      final alpha = (dt / (tau + dt)).clamp(0.0, 1.0);
      for (var i = 0; i < 3; i++) {
        g[i] += alpha * (a[i] - g[i]);
      }
    }
    _lastTime = s.time;

    // --- impact ---------------------------------------------------------
    final calm = _refractoryUntil == null || s.time.isAfter(_refractoryUntil!);
    if (!inImpact && calm && dynMag >= thresholdG) {
      _impactStart = s.time;
      _peak = dynMag;
      _peakVec = dyn;
      _peakSaturated = s.saturated;
    } else if (inImpact) {
      if (dynMag > _peak) {
        _peak = dynMag;
        _peakVec = dyn;
      }
      _peakSaturated |= s.saturated;
      final elapsed = s.time.difference(_impactStart!);
      if (dynMag < thresholdG * 0.5 || elapsed >= maxImpactDuration) {
        final n = _norm(_peakVec);
        events.add(MotionEvent(
          kind: MotionEventKind.impact,
          time: _impactStart!,
          peakG: _peak,
          duration: elapsed,
          direction: n == 0 ? const [0, 0, 0] : [for (final v in _peakVec) v / n],
          saturated: _peakSaturated,
        ));
        _impactStart = null;
        _refractoryUntil = s.time.add(refractory);
      }
    }

    // --- free fall --------------------------------------------------------
    if (total < freeFallG) {
      _fallStart ??= s.time;
      _fallMin = math.min(_fallMin, total);
      final elapsed = s.time.difference(_fallStart!);
      if (!_fallReported && elapsed >= freeFallMin) {
        _fallReported = true;
        events.add(MotionEvent(
          kind: MotionEventKind.freeFall,
          time: _fallStart!,
          peakG: _fallMin,
          duration: elapsed,
          direction: const [0, 0, 0],
        ));
      }
    } else {
      _fallStart = null;
      _fallMin = 1;
      _fallReported = false;
    }

    return events;
  }

  static double _norm(List<double> v) =>
      math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
}
