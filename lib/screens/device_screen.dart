import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../widgets/signal_chart.dart';
import '../witmotion/impact_detector.dart';
import '../witmotion/protocol.dart';
import '../witmotion/witmotion_device.dart';

const _xColor = Color(0xFFE5484D);
const _yColor = Color(0xFF30A46C);
const _zColor = Color(0xFF0A7CFF);

class DeviceScreen extends StatefulWidget {
  const DeviceScreen({super.key, required this.device});
  final BluetoothDevice device;

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> with SingleTickerProviderStateMixin {
  late final WitMotionDevice _wit = WitMotionDevice(widget.device);
  late final AnimationController _flash =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  StreamSubscription<MotionEvent>? _eventSub;
  MotionEvent? _flashEvent;

  @override
  void initState() {
    super.initState();
    _eventSub = _wit.eventStream.listen((e) {
      if (e.kind == MotionEventKind.impact) {
        HapticFeedback.heavyImpact();
        setState(() => _flashEvent = e);
        _flash.forward(from: 0);
      }
    });
    _wit.connect();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _flash.dispose();
    _wit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _wit,
      builder: (context, _) {
        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_wit.name),
                  Text(_stageLabel(_wit), style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
              actions: [
                if (_wit.stage == LinkStage.disconnected || _wit.stage == LinkStage.failed)
                  TextButton.icon(onPressed: _wit.connect, icon: const Icon(Icons.refresh), label: const Text('Reconnect'))
                else if (_wit.isReady)
                  TextButton.icon(
                      onPressed: _wit.disconnect, icon: const Icon(Icons.link_off), label: const Text('Disconnect')),
              ],
              bottom: const TabBar(tabs: [
                Tab(icon: Icon(Icons.show_chart), text: 'Live'),
                Tab(icon: Icon(Icons.flash_on), text: 'Impacts'),
                Tab(icon: Icon(Icons.info_outline), text: 'Attributes'),
              ]),
            ),
            body: Stack(
              children: [
                if (!_wit.isReady && _wit.latest == null)
                  _ConnectingView(wit: _wit)
                else
                  TabBarView(children: [
                    _LiveTab(wit: _wit),
                    _ImpactsTab(wit: _wit),
                    _AttributesTab(wit: _wit),
                  ]),
                _ImpactFlash(animation: _flash, event: _flashEvent),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _stageLabel(WitMotionDevice w) => switch (w.stage) {
        LinkStage.idle || LinkStage.connecting => 'Connecting…',
        LinkStage.discovering => 'Discovering services…',
        LinkStage.subscribing => 'Subscribing to data…',
        LinkStage.ready => 'Connected · ${w.measuredHz.toStringAsFixed(0)} Hz',
        LinkStage.disconnected => 'Disconnected',
        LinkStage.failed => 'Connection failed',
      };
}

// ---------------------------------------------------------------------------

class _ConnectingView extends StatelessWidget {
  const _ConnectingView({required this.wit});
  final WitMotionDevice wit;

  @override
  Widget build(BuildContext context) {
    final failed = wit.stage == LinkStage.failed || wit.stage == LinkStage.disconnected;
    final steps = [
      (LinkStage.connecting, 'Connect'),
      (LinkStage.discovering, 'Discover GATT services'),
      (LinkStage.subscribing, 'Subscribe to FFE4 notifications'),
    ];
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (failed)
              Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error)
            else
              const CircularProgressIndicator(),
            const SizedBox(height: 24),
            for (final (stage, label) in steps)
              ListTile(
                dense: true,
                leading: Icon(
                  wit.stage.index > stage.index && !failed
                      ? Icons.check_circle
                      : wit.stage == stage
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                ),
                title: Text(label),
              ),
            if (wit.error != null) ...[
              const SizedBox(height: 16),
              Text(wit.error!, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (failed) ...[
              const SizedBox(height: 16),
              FilledButton.icon(onPressed: wit.connect, icon: const Icon(Icons.refresh), label: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}

class _ImpactFlash extends StatelessWidget {
  const _ImpactFlash({required this.animation, required this.event});
  final Animation<double> animation;
  final MotionEvent? event;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) {
          final t = animation.value;
          if (t == 0 || t == 1 || event == null) return const SizedBox.shrink();
          final opacity = (1 - t).clamp(0.0, 1.0);
          final color = _severityColor(event!.severity);
          return Container(
            color: color.withValues(alpha: 0.25 * opacity),
            alignment: Alignment.center,
            child: Opacity(
              opacity: opacity,
              child: Transform.scale(
                scale: 0.8 + 0.4 * Curves.easeOutBack.transform(t.clamp(0, 1)),
                child: Card(
                  color: color,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text('IMPACT', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, letterSpacing: 2)),
                      Text('${event!.peakG.toStringAsFixed(1)} g',
                          style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w700)),
                      Text(event!.dominantAxis, style: const TextStyle(color: Colors.white)),
                    ]),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

Color _severityColor(ImpactSeverity s) => switch (s) {
      ImpactSeverity.light => const Color(0xFFF5A524),
      ImpactSeverity.moderate => const Color(0xFFF76B15),
      ImpactSeverity.severe => const Color(0xFFE5484D),
    };

// ---------------------------------------------------------------------------

class _LiveTab extends StatelessWidget {
  const _LiveTab({required this.wit});
  final WitMotionDevice wit;

  @override
  Widget build(BuildContext context) {
    final s = wit.latest;
    if (s == null) return const Center(child: Text('Waiting for data…'));
    final h = wit.history.toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Section(
          title: 'Acceleration',
          trailing: '|a| ${wit.detector.lastTotalG.toStringAsFixed(2)} g',
          child: Column(children: [
            _AxisRow(values: [s.ax, s.ay, s.az], unit: 'g', digits: 3),
            const SizedBox(height: 12),
            SignalChart(
              capacity: WitMotionDevice.historyLength,
              series: [
                ChartSeries('X', _xColor, [for (final r in h) r[0]]),
                ChartSeries('Y', _yColor, [for (final r in h) r[1]]),
                ChartSeries('Z', _zColor, [for (final r in h) r[2]]),
              ],
            ),
          ]),
        ),
        _Section(
          title: 'Angular velocity',
          child: _AxisRow(values: [s.gx, s.gy, s.gz], unit: '°/s', digits: 1),
        ),
        _Section(
          title: 'Angle',
          child: _AxisRow(values: [s.roll, s.pitch, s.yaw], labels: const ['Roll', 'Pitch', 'Yaw'], unit: '°', digits: 1),
        ),
      ],
    );
  }
}

class _ImpactsTab extends StatelessWidget {
  const _ImpactsTab({required this.wit});
  final WitMotionDevice wit;

  @override
  Widget build(BuildContext context) {
    final impacts = wit.events.where((e) => e.kind == MotionEventKind.impact).toList();
    final peak = impacts.isEmpty ? null : impacts.map((e) => e.peakG).reduce((a, b) => a > b ? a : b);
    final rate = wit.attributes.returnRate?.hz ?? wit.measuredHz.round();
    final text = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(children: [
          Expanded(child: _Stat(label: 'Impacts', value: '${impacts.length}')),
          Expanded(child: _Stat(label: 'Peak', value: peak == null ? '—' : '${peak.toStringAsFixed(1)} g')),
          Expanded(child: _Stat(label: 'Now', value: '${wit.detector.lastDynamicG.toStringAsFixed(2)} g')),
        ]),
        const SizedBox(height: 8),
        if (rate > 0 && rate < 50)
          Card(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: ListTile(
              leading: const Icon(Icons.speed),
              title: Text('Output rate is $rate Hz'),
              subtitle: const Text('Short knocks last a few milliseconds. Use 100–200 Hz to catch real impact peaks.'),
              trailing: TextButton(
                onPressed: () => _run(context, () => wit.setReturnRate(ReturnRate.hz100), 'Output rate set to 100 Hz'),
                child: const Text('100 Hz'),
              ),
            ),
          ),
        _Section(
          title: 'Dynamic acceleration (gravity removed)',
          child: SignalChart(
            capacity: WitMotionDevice.historyLength,
            minY: 0,
            threshold: wit.detector.thresholdG,
            series: [
              ChartSeries('|a − g|', Theme.of(context).colorScheme.primary, [for (final r in wit.history) r[3]]),
            ],
          ),
        ),
        _Section(
          title: 'Impact threshold',
          trailing: '${wit.detector.thresholdG.toStringAsFixed(1)} g',
          child: Slider(
            value: wit.detector.thresholdG,
            min: 0.5,
            max: 12,
            divisions: 23,
            label: '${wit.detector.thresholdG.toStringAsFixed(1)} g',
            onChanged: wit.setThreshold,
          ),
        ),
        Row(children: [
          Text('Event log', style: text.titleMedium),
          const Spacer(),
          TextButton.icon(onPressed: wit.events.isEmpty ? null : wit.clearEvents, icon: const Icon(Icons.delete_outline), label: const Text('Clear')),
        ]),
        if (wit.events.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Tap or drop the sensor to record an impact.', textAlign: TextAlign.center),
          ),
        for (final e in wit.events) _EventTile(event: e),
      ],
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});
  final MotionEvent event;

  @override
  Widget build(BuildContext context) {
    final t = event.time;
    final time = '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
    if (event.kind == MotionEventKind.freeFall) {
      return ListTile(
        leading: const CircleAvatar(child: Icon(Icons.south)),
        title: const Text('Free fall'),
        subtitle: Text('$time · ${event.duration.inMilliseconds} ms · min ${event.peakG.toStringAsFixed(2)} g'),
      );
    }
    final color = _severityColor(event.severity);
    return ListTile(
      leading: CircleAvatar(backgroundColor: color, foregroundColor: Colors.white, child: const Icon(Icons.flash_on)),
      title: Text('${event.peakG.toStringAsFixed(2)} g${event.saturated ? '+ (sensor clipped)' : ''}'),
      subtitle: Text('$time · ${event.severity.name} · axis ${event.dominantAxis} · ${event.duration.inMilliseconds} ms'),
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}

class _AttributesTab extends StatelessWidget {
  const _AttributesTab({required this.wit});
  final WitMotionDevice wit;

  @override
  Widget build(BuildContext context) {
    final a = wit.attributes;
    String fmt(List<double>? v, int d) => v == null ? '—' : v.map((e) => e.toStringAsFixed(d)).join(', ');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Section(
          title: 'Device',
          child: Column(children: [
            _KV('Name', wit.name),
            _KV('Remote ID', wit.device.remoteId.str),
            _KV('RSSI', wit.rssi == null ? '—' : '${wit.rssi} dBm'),
            _KV('MTU', '${wit.mtu}'),
            _KV('Firmware (reg 0x2E)', a.versionHex ?? '—'),
            _KV('Battery', a.batteryVolts == null ? '—' : '${a.batteryVolts!.toStringAsFixed(2)} V · ~${a.batteryPercent}%'),
            _KV('Temperature', a.temperatureC == null ? '—' : '${a.temperatureC!.toStringAsFixed(1)} °C'),
          ]),
        ),
        _Section(
          title: 'Stream',
          child: Column(children: [
            _KV('Configured rate', a.returnRate == null ? '—' : '${a.returnRate!.hz} Hz'),
            _KV('Measured rate', '${wit.measuredHz.toStringAsFixed(1)} Hz'),
            _KV('Packets received', '${wit.packetCount}'),
          ]),
        ),
        _Section(
          title: 'Sensors',
          child: Column(children: [
            _KV('Magnetic field (µT)', fmt(a.magneticField, 1)),
            _KV('Quaternion', fmt(a.quaternion, 4)),
          ]),
        ),
        _Section(
          title: 'Configuration',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Expanded(child: Text('Output rate')),
              DropdownButton<ReturnRate>(
                value: a.returnRate,
                hint: const Text('—'),
                items: [for (final r in ReturnRate.values) DropdownMenuItem(value: r, child: Text('${r.hz} Hz'))],
                onChanged: !wit.isReady
                    ? null
                    : (r) => r == null ? null : _run(context, () => wit.setReturnRate(r), 'Output rate set to ${r.hz} Hz'),
              ),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                onPressed: !wit.isReady
                    ? null
                    : () => _run(context, wit.calibrateAccelerometer, 'Accelerometer calibrated',
                        progress: 'Calibrating… keep the sensor flat and still'),
                icon: const Icon(Icons.straighten),
                label: const Text('Calibrate accelerometer'),
              ),
              OutlinedButton.icon(
                onPressed: !wit.isReady ? null : () => _run(context, wit.zeroYaw, 'Yaw reset to 0°'),
                icon: const Icon(Icons.explore_outlined),
                label: const Text('Zero yaw'),
              ),
            ]),
          ]),
        ),
        _Section(
          title: 'GATT services',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final s in wit.services) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Service ${s.uuid.str128}', style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600, fontSize: 12)),
                ),
                for (final c in s.characteristics)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, top: 4),
                    child: Text(
                      '${c.uuid.str128}  [${_props(c.properties)}]'
                      '${c == wit.notifyChar ? '  ← data' : c == wit.writeChar ? '  ← commands' : ''}',
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  static String _props(CharacteristicProperties p) => [
        if (p.read) 'read',
        if (p.write) 'write',
        if (p.writeWithoutResponse) 'writeNoResp',
        if (p.notify) 'notify',
        if (p.indicate) 'indicate',
      ].join(', ');
}

Future<void> _run(BuildContext context, Future<void> Function() action, String done, {String? progress}) async {
  final messenger = ScaffoldMessenger.of(context);
  if (progress != null) messenger.showSnackBar(SnackBar(content: Text(progress), duration: const Duration(seconds: 4)));
  try {
    await action();
    messenger.showSnackBar(SnackBar(content: Text(done)));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
  }
}

// ---------------------------------------------------------------------------

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});
  final String title;
  final String? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall)),
              if (trailing != null) Text(trailing!, style: Theme.of(context).textTheme.labelMedium),
            ]),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _AxisRow extends StatelessWidget {
  const _AxisRow({required this.values, required this.unit, required this.digits, this.labels = const ['X', 'Y', 'Z']});
  final List<double> values;
  final List<String> labels;
  final String unit;
  final int digits;

  @override
  Widget build(BuildContext context) {
    const colors = [_xColor, _yColor, _zColor];
    return Row(children: [
      for (var i = 0; i < 3; i++)
        Expanded(
          child: Column(children: [
            Text(labels[i], style: TextStyle(color: colors[i], fontWeight: FontWeight.w600)),
            Text('${values[i].toStringAsFixed(digits)} $unit',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        ),
    ]);
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label, value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(children: [
          Text(value, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          Text(label, style: Theme.of(context).textTheme.labelMedium),
        ]),
      ),
    );
  }
}

class _KV extends StatelessWidget {
  const _KV(this.k, this.v);
  final String k, v;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(child: Text(k, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
        Flexible(child: Text(v, textAlign: TextAlign.right)),
      ]),
    );
  }
}
