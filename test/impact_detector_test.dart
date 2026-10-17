import 'package:flutter_test/flutter_test.dart';
import 'package:witmotion_demo/witmotion/impact_detector.dart';
import 'package:witmotion_demo/witmotion/protocol.dart';

final _t0 = DateTime(2026);

ImuSample _s(int ms, double ax, double ay, double az, {bool saturated = false}) => ImuSample(
      time: _t0.add(Duration(milliseconds: ms)),
      ax: ax, ay: ay, az: az, gx: 0, gy: 0, gz: 0, roll: 0, pitch: 0, yaw: 0,
      saturated: saturated,
    );

/// Feeds samples at 100 Hz starting at [startMs]; returns collected events.
List<MotionEvent> _feed(ImpactDetector d, List<List<double>> samples, {int startMs = 0}) => [
      for (var i = 0; i < samples.length; i++)
        ...d.add(_s(startMs + i * 10, samples[i][0], samples[i][1], samples[i][2])),
    ];

void main() {
  test('no events while resting', () {
    final d = ImpactDetector();
    expect(_feed(d, List.filled(200, [0.0, 0.0, 1.0])), isEmpty);
    expect(d.lastDynamicG, closeTo(0, 1e-6));
  });

  test('detects a single impact with peak and direction', () {
    final d = ImpactDetector(thresholdG: 2);
    _feed(d, List.filled(100, [0.0, 0.0, 1.0]));
    final events = _feed(d, [
      [3.0, 0.0, 1.0],
      [-6.0, 0.5, 1.0], // peak 6.02 g along -X
      [2.0, 0.0, 1.0],
      [0.1, 0.0, 1.0],
      ...List.filled(20, [0.0, 0.0, 1.0]),
    ], startMs: 1000);
    expect(events, hasLength(1));
    final e = events.single;
    expect(e.kind, MotionEventKind.impact);
    expect(e.peakG, closeTo(6.02, 0.01));
    expect(e.dominantAxis, '-X');
    expect(e.severity, ImpactSeverity.moderate);
  });

  test('ringing within the refractory period is one impact', () {
    final d = ImpactDetector(thresholdG: 2);
    _feed(d, List.filled(100, [0.0, 0.0, 1.0]));
    final events = _feed(d, [
      [0.0, 0.0, 9.0], [0.0, 0.0, 1.0], [0.0, 0.0, 4.0], [0.0, 0.0, 1.0],
      ...List.filled(50, [0.0, 0.0, 1.0]),
    ], startMs: 1000);
    expect(events.where((e) => e.kind == MotionEventKind.impact), hasLength(1));
    expect(events.first.severity, ImpactSeverity.severe);
  });

  test('works regardless of mounting orientation', () {
    final d = ImpactDetector(thresholdG: 2);
    // gravity on +Y instead of +Z
    expect(_feed(d, List.filled(200, [0.0, 1.0, 0.0])), isEmpty);
    final events = _feed(d, [[0.0, 1.0, 3.5], [0.0, 1.0, 0.0], ...List.filled(10, [0.0, 1.0, 0.0])], startMs: 2000);
    expect(events.single.dominantAxis, '+Z');
  });

  test('detects free fall followed by the landing impact', () {
    final d = ImpactDetector(thresholdG: 2);
    _feed(d, List.filled(100, [0.0, 0.0, 1.0]));
    final events = _feed(d, [
      ...List.filled(25, [0.0, 0.0, 0.05]), // 250 ms of free fall
      [0.0, 0.0, 7.0],
      ...List.filled(30, [0.0, 0.0, 1.0]),
    ], startMs: 1000);
    expect(events.map((e) => e.kind), [MotionEventKind.freeFall, MotionEventKind.impact]);
  });
}
