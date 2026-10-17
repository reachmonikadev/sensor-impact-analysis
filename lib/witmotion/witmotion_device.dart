import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'impact_detector.dart';
import 'protocol.dart';

enum LinkStage { idle, connecting, discovering, subscribing, ready, disconnected, failed }

/// Owns the BLE link to one WitMotion sensor: connects, finds the data
/// characteristics, decodes the stream, polls attribute registers and runs
/// impact detection. UI listens via [ChangeNotifier] (throttled to ~30 fps).
class WitMotionDevice extends ChangeNotifier {
  WitMotionDevice(this.device);

  final BluetoothDevice device;

  static const int historyLength = 300;

  LinkStage stage = LinkStage.idle;
  String? error;

  List<BluetoothService> services = const [];
  BluetoothCharacteristic? notifyChar;
  BluetoothCharacteristic? writeChar;

  ImuSample? latest;
  final Map<int, int> registers = {};
  WitAttributes get attributes => WitAttributes(registers);

  int? rssi;
  int mtu = 23;
  int packetCount = 0;
  double measuredHz = 0;

  final ImpactDetector detector = ImpactDetector();
  final List<MotionEvent> events = [];

  /// Rolling history for charts: (ax, ay, az, dynamicG).
  final Queue<List<double>> history = Queue();

  /// Fires once per detected event (for flashes / haptics in the UI).
  final StreamController<MotionEvent> _eventCtrl = StreamController.broadcast();
  Stream<MotionEvent> get eventStream => _eventCtrl.stream;

  final WitPacketParser _parser = WitPacketParser();
  StreamSubscription<List<int>>? _dataSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _pollTimer, _uiTimer, _rssiTimer;
  int _pollIndex = 0;
  int _packetsThisSecond = 0;
  DateTime _rateWindow = DateTime.now();
  bool _dirty = false;
  bool _disposed = false;
  bool _busyCommand = false;

  /// Registers polled in rotation. Each read returns 8 consecutive registers,
  /// so 0x3A also yields the temperature at 0x40.
  static const List<int> _pollRegisters = [
    WitReg.hx, // magnetic field + temperature
    WitReg.q0, // quaternion
    WitReg.battery,
    WitReg.version,
    WitReg.rrate,
  ];

  String get name =>
      device.advName.isNotEmpty ? device.advName : (device.platformName.isNotEmpty ? device.platformName : 'Unknown');

  bool get isReady => stage == LinkStage.ready;

  Future<void> connect() async {
    error = null;
    _setStage(LinkStage.connecting);
    try {
      _connSub ??= device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected &&
            (stage == LinkStage.ready || stage == LinkStage.subscribing)) {
          _stopTimers();
          _setStage(LinkStage.disconnected);
        }
      });

      // License.nonprofit is fine for a demo; commercial products need a
      // flutter_blue_plus commercial license.
      await device.connect(license: License.nonprofit, timeout: const Duration(seconds: 15));
      mtu = device.mtuNow;

      _setStage(LinkStage.discovering);
      services = await device.discoverServices();
      for (final s in services) {
        for (final c in s.characteristics) {
          final id = shortUuid(c.uuid.str128);
          if (id == kNotifyShortId) notifyChar = c;
          if (id == kWriteShortId) writeChar = c;
        }
      }
      if (notifyChar == null) {
        throw StateError('No WitMotion data characteristic (FFE4) found. '
            'Is this a WitMotion BLE 5.0 sensor?');
      }

      _setStage(LinkStage.subscribing);
      _dataSub = notifyChar!.onValueReceived.listen(_onData);
      device.cancelWhenDisconnected(_dataSub!);
      await notifyChar!.setNotifyValue(true);

      _startTimers();
      _setStage(LinkStage.ready);
    } catch (e) {
      error = e.toString();
      _setStage(LinkStage.failed);
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }

  Future<void> disconnect() async {
    _stopTimers();
    await _dataSub?.cancel();
    _dataSub = null;
    try {
      await device.disconnect();
    } catch (_) {}
    _setStage(LinkStage.disconnected);
  }

  void _onData(List<int> bytes) {
    for (final packet in _parser.add(bytes)) {
      if (packet is ImuSample) {
        _onSample(packet);
      } else if (packet is RegisterReply) {
        for (var i = 0; i < packet.values.length; i++) {
          registers[packet.startRegister + i] = packet.values[i];
        }
      }
    }
    _dirty = true;
  }

  void _onSample(ImuSample s) {
    latest = s;
    packetCount++;
    _packetsThisSecond++;

    final newEvents = detector.add(s);
    history.add([s.ax, s.ay, s.az, detector.lastDynamicG]);
    while (history.length > historyLength) {
      history.removeFirst();
    }
    for (final e in newEvents) {
      events.insert(0, e);
      _eventCtrl.add(e);
    }
    if (events.length > 200) events.removeRange(200, events.length);
  }

  void clearEvents() {
    events.clear();
    notifyListeners();
  }

  void setThreshold(double g) {
    detector.thresholdG = g;
    notifyListeners();
  }

  // ---- commands --------------------------------------------------------

  Future<void> _send(List<int> cmd) async {
    final c = writeChar;
    if (c == null) throw StateError('Write characteristic (FFE9) not found');
    await c.write(cmd, withoutResponse: c.properties.writeWithoutResponse && !c.properties.write);
  }

  /// Runs an unlock → command(s) → save sequence used for config changes.
  Future<void> _configure(List<List<int>> commands, {bool save = true}) async {
    _busyCommand = true;
    try {
      await _send(WitCommand.unlock());
      await Future.delayed(const Duration(milliseconds: 100));
      for (final cmd in commands) {
        await _send(cmd);
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (save) await _send(WitCommand.save());
    } finally {
      _busyCommand = false;
    }
  }

  Future<void> setReturnRate(ReturnRate rate) async {
    await _configure([WitCommand.setReturnRate(rate)]);
    detector.reset();
    await readRegister(WitReg.rrate);
  }

  /// Accelerometer calibration: keep the sensor flat and still.
  Future<void> calibrateAccelerometer() async {
    _busyCommand = true;
    try {
      await _send(WitCommand.unlock());
      await Future.delayed(const Duration(milliseconds: 100));
      await _send(WitCommand.startAccCalibration());
      await Future.delayed(const Duration(seconds: 3));
      await _send(WitCommand.stopCalibration());
      await Future.delayed(const Duration(milliseconds: 100));
      await _send(WitCommand.save());
    } finally {
      _busyCommand = false;
    }
    detector.reset();
  }

  Future<void> zeroYaw() => _configure([WitCommand.zeroYaw()]);

  Future<void> readRegister(int reg) => _send(WitCommand.readRegister(reg));

  // ---- timers ----------------------------------------------------------

  void _startTimers() {
    _uiTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      final now = DateTime.now();
      if (now.difference(_rateWindow) >= const Duration(seconds: 1)) {
        measuredHz = _packetsThisSecond * 1000 / now.difference(_rateWindow).inMilliseconds;
        _packetsThisSecond = 0;
        _rateWindow = now;
        _dirty = true;
      }
      if (_dirty) {
        _dirty = false;
        notifyListeners();
      }
    });

    _pollTimer = Timer.periodic(const Duration(milliseconds: 400), (_) async {
      if (_busyCommand || writeChar == null) return;
      final reg = _pollRegisters[_pollIndex++ % _pollRegisters.length];
      try {
        await readRegister(reg);
      } catch (_) {
        // Polling is best-effort; the stream keeps flowing regardless.
      }
    });

    _rssiTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        rssi = await device.readRssi();
        _dirty = true;
      } catch (_) {}
    });
  }

  void _stopTimers() {
    _pollTimer?.cancel();
    _uiTimer?.cancel();
    _rssiTimer?.cancel();
    _pollTimer = _uiTimer = _rssiTimer = null;
  }

  void _setStage(LinkStage s) {
    stage = s;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTimers();
    _dataSub?.cancel();
    _connSub?.cancel();
    _eventCtrl.close();
    device.disconnect().catchError((_) {});
    super.dispose();
  }
}
