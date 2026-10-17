/// WitMotion BLE 5.0 protocol (BWT901BLECL, WT9011DCL, WT901BLE5.0 …).
///
/// Data flows over a vendor GATT service:
///   service  0000ffe5-0000-1000-8000-00805f9a34fb
///   notify   0000ffe4-…  (sensor → phone, 20-byte packets)
///   write    0000ffe9-…  (phone → sensor, 5-byte commands)
///
/// Note: WitMotion uses the base `…-00805f9a34fb` (not the standard
/// `…-00805f9b34fb`), so characteristics are matched on the 16-bit short id.
library;

const String kNotifyShortId = 'ffe4';
const String kWriteShortId = 'ffe9';
const String kServiceShortId = 'ffe5';

/// Extracts the 16-bit short id ("ffe4") from a 128-bit UUID string,
/// regardless of which Bluetooth base UUID the vendor used.
String shortUuid(String uuid128) {
  final s = uuid128.toLowerCase();
  if (s.length == 4) return s;
  if (s.length >= 8) return s.substring(4, 8);
  return s;
}

/// Register addresses (see WitMotion "WIT standard protocol").
abstract final class WitReg {
  static const save = 0x00;
  static const calsw = 0x01;
  static const rrate = 0x03;
  static const version = 0x2E;
  static const hx = 0x3A;
  static const hy = 0x3B;
  static const hz = 0x3C;
  static const temp = 0x40;
  static const q0 = 0x51;
  static const battery = 0x64;
  static const unlock = 0x69;
  static const readAddr = 0x27;
}

/// Output-rate codes for register 0x03 (RRATE).
enum ReturnRate {
  hz1(0x03, 1),
  hz10(0x06, 10),
  hz20(0x07, 20),
  hz50(0x08, 50),
  hz100(0x09, 100),
  hz200(0x0B, 200);

  const ReturnRate(this.code, this.hz);
  final int code;
  final int hz;

  static ReturnRate? fromCode(int code) {
    for (final r in values) {
      if (r.code == code) return r;
    }
    return null;
  }
}

/// 5-byte command frames: `FF AA reg dataL dataH`.
abstract final class WitCommand {
  static List<int> write(int reg, int value) =>
      [0xFF, 0xAA, reg & 0xFF, value & 0xFF, (value >> 8) & 0xFF];

  static List<int> unlock() => write(WitReg.unlock, 0xB588);
  static List<int> save() => write(WitReg.save, 0x0000);
  static List<int> readRegister(int reg) => write(WitReg.readAddr, reg);
  static List<int> setReturnRate(ReturnRate rate) =>
      write(WitReg.rrate, rate.code);

  /// Start/stop accelerometer calibration (sensor must lie flat & still).
  static List<int> startAccCalibration() => write(WitReg.calsw, 0x0001);
  static List<int> stopCalibration() => write(WitReg.calsw, 0x0000);

  /// Reset relative yaw (Z-axis angle) to zero.
  static List<int> zeroYaw() => write(WitReg.calsw, 0x0004);
}

/// One accelerometer / gyroscope / angle sample from a 0x55 0x61 packet.
class ImuSample {
  const ImuSample({
    required this.time,
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.roll,
    required this.pitch,
    required this.yaw,
    this.saturated = false,
  });

  final DateTime time;

  /// Acceleration in g (range ±16 g).
  final double ax, ay, az;

  /// Angular velocity in °/s (range ±2000 °/s).
  final double gx, gy, gz;

  /// Euler angles in degrees.
  final double roll, pitch, yaw;

  /// True when any accelerometer axis hit full scale, i.e. the real peak
  /// was larger than what the sensor could report.
  final bool saturated;
}

/// Reply to a register read: `55 71 regL regH` + 8 × int16.
class RegisterReply {
  const RegisterReply(this.startRegister, this.values);
  final int startRegister;
  final List<int> values;
}

/// Reassembles the notification byte stream into packets.
///
/// Packets are 20 bytes and start with 0x55. BLE notifications usually carry
/// exactly one packet, but with a larger MTU several can be concatenated, and
/// a stray byte may appear after reconnects — so we resync on the header.
class WitPacketParser {
  static const int packetLength = 20;
  static const int flagImu = 0x61;
  static const int flagRegister = 0x71;

  final List<int> _buffer = [];

  /// Feeds raw bytes and returns every complete packet decoded from them
  /// (either [ImuSample] or [RegisterReply]).
  List<Object> add(List<int> bytes, {DateTime? now}) {
    _buffer.addAll(bytes);
    final out = <Object>[];
    final time = now ?? DateTime.now();

    while (_buffer.length >= packetLength) {
      final isHeader = _buffer[0] == 0x55 &&
          (_buffer[1] == flagImu || _buffer[1] == flagRegister);
      if (!isHeader) {
        _buffer.removeAt(0);
        continue;
      }
      final p = _buffer.sublist(0, packetLength);
      _buffer.removeRange(0, packetLength);
      if (p[1] == flagImu) {
        out.add(decodeImu(p, time));
      } else {
        out.add(decodeRegisters(p));
      }
    }
    // Avoid unbounded growth if the stream is garbage.
    if (_buffer.length > 4 * packetLength) _buffer.clear();
    return out;
  }

  static int int16(List<int> p, int i) {
    final v = p[i] | (p[i + 1] << 8);
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  static ImuSample decodeImu(List<int> p, DateTime time) {
    final rawAx = int16(p, 2), rawAy = int16(p, 4), rawAz = int16(p, 6);
    double acc(int v) => v / 32768.0 * 16.0;
    double gyro(int v) => v / 32768.0 * 2000.0;
    double angle(int v) => v / 32768.0 * 180.0;
    bool full(int v) => v >= 32760 || v <= -32760;
    return ImuSample(
      time: time,
      ax: acc(rawAx),
      ay: acc(rawAy),
      az: acc(rawAz),
      gx: gyro(int16(p, 8)),
      gy: gyro(int16(p, 10)),
      gz: gyro(int16(p, 12)),
      roll: angle(int16(p, 14)),
      pitch: angle(int16(p, 16)),
      yaw: angle(int16(p, 18)),
      saturated: full(rawAx) || full(rawAy) || full(rawAz),
    );
  }

  static RegisterReply decodeRegisters(List<int> p) {
    final start = p[2] | (p[3] << 8);
    return RegisterReply(start, [for (var i = 0; i < 8; i++) int16(p, 4 + i * 2)]);
  }
}

/// Converts raw register values into human-readable attributes.
class WitAttributes {
  WitAttributes(this.registers);

  /// register address → raw signed 16-bit value
  final Map<int, int> registers;

  int? _r(int reg) => registers[reg];

  double? get temperatureC => _r(WitReg.temp) == null ? null : _r(WitReg.temp)! / 100.0;

  double? get batteryVolts =>
      _r(WitReg.battery) == null ? null : (_r(WitReg.battery)! & 0xFFFF) / 100.0;

  /// Approximate charge using WitMotion's voltage table for the Li-ion cell.
  int? get batteryPercent {
    final raw = _r(WitReg.battery);
    if (raw == null) return null;
    final v = raw & 0xFFFF;
    const table = [
      (396, 100), (393, 90), (387, 75), (382, 60), (379, 50),
      (377, 40), (373, 30), (370, 20), (368, 15), (350, 10), (340, 5),
    ];
    for (final (threshold, pct) in table) {
      if (v > threshold) return pct;
    }
    return 0;
  }

  /// Magnetic field in µT (raw / 120, per WitMotion's BLE SDK).
  List<double>? get magneticField {
    final x = _r(WitReg.hx), y = _r(WitReg.hy), z = _r(WitReg.hz);
    if (x == null || y == null || z == null) return null;
    return [x / 120.0, y / 120.0, z / 120.0];
  }

  List<double>? get quaternion {
    final q = [for (var i = 0; i < 4; i++) _r(WitReg.q0 + i)];
    if (q.contains(null)) return null;
    return [for (final v in q) v! / 32768.0];
  }

  ReturnRate? get returnRate =>
      _r(WitReg.rrate) == null ? null : ReturnRate.fromCode(_r(WitReg.rrate)!);

  /// Firmware version registers 0x2E/0x2F shown as raw hex.
  String? get versionHex {
    final a = _r(WitReg.version), b = _r(WitReg.version + 1);
    if (a == null || b == null) return null;
    String h(int v) => (v & 0xFFFF).toRadixString(16).padLeft(4, '0').toUpperCase();
    return '0x${h(b)}${h(a)}';
  }
}
