import 'package:flutter_test/flutter_test.dart';
import 'package:witmotion_demo/witmotion/protocol.dart';

List<int> _le(int v) => [v & 0xFF, (v >> 8) & 0xFF];

List<int> imuPacket({int ax = 0, int ay = 0, int az = 2048, int gx = 0, int roll = 0, int yaw = 0}) =>
    [0x55, 0x61, ..._le(ax), ..._le(ay), ..._le(az), ..._le(gx), 0, 0, 0, 0, ..._le(roll), 0, 0, ..._le(yaw)];

void main() {
  test('matches WitMotion characteristics despite non-standard base UUID', () {
    expect(shortUuid('0000ffe4-0000-1000-8000-00805f9a34fb'), kNotifyShortId);
    expect(shortUuid('0000FFE9-0000-1000-8000-00805F9B34FB'), kWriteShortId);
  });

  test('builds command frames', () {
    expect(WitCommand.unlock(), [0xFF, 0xAA, 0x69, 0x88, 0xB5]);
    expect(WitCommand.save(), [0xFF, 0xAA, 0x00, 0x00, 0x00]);
    expect(WitCommand.readRegister(0x3A), [0xFF, 0xAA, 0x27, 0x3A, 0x00]);
    expect(WitCommand.setReturnRate(ReturnRate.hz100), [0xFF, 0xAA, 0x03, 0x09, 0x00]);
  });

  test('decodes an IMU packet', () {
    // 2048 raw = 1 g, 0x4000 raw = 90°, -16384 = -1000 °/s
    final out = WitPacketParser().add(imuPacket(az: 2048, gx: 0x10000 - 16384, roll: 0x4000));
    expect(out, hasLength(1));
    final s = out.single as ImuSample;
    expect(s.az, closeTo(1.0, 1e-9));
    expect(s.gx, closeTo(-1000, 1e-9));
    expect(s.roll, closeTo(90, 1e-9));
    expect(s.saturated, isFalse);
  });

  test('flags accelerometer saturation', () {
    final s = WitPacketParser().add(imuPacket(ax: 0x7FFF)).single as ImuSample;
    expect(s.saturated, isTrue);
  });

  test('resyncs on garbage and handles split + concatenated packets', () {
    final p = WitPacketParser();
    final a = imuPacket(az: 2048), b = imuPacket(az: 4096);
    expect(p.add([0x00, 0x12, ...a.sublist(0, 7)]), isEmpty);
    final out = p.add([...a.sublist(7), ...b]);
    expect(out, hasLength(2));
    expect((out[1] as ImuSample).az, closeTo(2.0, 1e-9));
  });

  test('decodes register replies into attributes', () {
    // reply for 0x3A: Hx, Hy, Hz, (3 others), temp at 0x40 = 25.37 °C, 0x41
    final reply = [0x55, 0x71, 0x3A, 0x00, ..._le(1200), ..._le(0x10000 - 240), ..._le(0), 0, 0, 0, 0, 0, 0, ..._le(2537), 0, 0];
    final r = WitPacketParser().add(reply).single as RegisterReply;
    final regs = <int, int>{for (var i = 0; i < 8; i++) r.startRegister + i: r.values[i]};
    regs[WitReg.battery] = 390;
    regs[WitReg.rrate] = 0x08;
    final attrs = WitAttributes(regs);
    expect(attrs.magneticField, [10.0, -2.0, 0.0]);
    expect(attrs.temperatureC, closeTo(25.37, 1e-9));
    expect(attrs.batteryVolts, closeTo(3.90, 1e-9));
    expect(attrs.batteryPercent, 75);
    expect(attrs.returnRate, ReturnRate.hz50);
  });
}
