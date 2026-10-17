import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../witmotion/protocol.dart';
import 'device_screen.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  BluetoothAdapterState _adapter = BluetoothAdapterState.unknown;
  List<ScanResult> _results = [];
  bool _scanning = false;
  bool _witOnly = true;
  String? _error;

  late final StreamSubscription<BluetoothAdapterState> _adapterSub;
  late final StreamSubscription<List<ScanResult>> _resultsSub;
  late final StreamSubscription<bool> _scanningSub;

  @override
  void initState() {
    super.initState();
    _adapterSub = FlutterBluePlus.adapterState.listen((s) {
      setState(() => _adapter = s);
      if (s == BluetoothAdapterState.on && _results.isEmpty && !_scanning) _startScan();
    });
    _resultsSub = FlutterBluePlus.scanResults.listen((r) => setState(() => _results = r));
    _scanningSub = FlutterBluePlus.isScanning.listen((s) => setState(() => _scanning = s));
  }

  @override
  void dispose() {
    _adapterSub.cancel();
    _resultsSub.cancel();
    _scanningSub.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() => _error = null);
    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        continuousUpdates: true,
        removeIfGone: const Duration(seconds: 5),
      );
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  static bool isWitMotion(ScanResult r) {
    final name = r.advertisementData.advName.toUpperCase();
    if (name.startsWith('WT') || name.contains('WIT') || name.startsWith('BWT')) return true;
    return r.advertisementData.serviceUuids
        .any((u) => const {'ffe5', 'ffe0'}.contains(shortUuid(u.str128)));
  }

  Future<void> _open(ScanResult r) async {
    await FlutterBluePlus.stopScan();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => DeviceScreen(device: r.device)));
  }

  @override
  Widget build(BuildContext context) {
    final visible = _results.where((r) => !_witOnly || isWitMotion(r)).toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    return Scaffold(
      appBar: AppBar(
        title: const Text('WitMotion Sensors'),
        actions: [
          if (_scanning)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_adapter != BluetoothAdapterState.on) _AdapterBanner(state: _adapter),
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              leading: const Icon(Icons.error_outline),
              actions: [TextButton(onPressed: () => setState(() => _error = null), child: const Text('Dismiss'))],
            ),
          SwitchListTile(
            title: const Text('Only WitMotion devices'),
            subtitle: Text('${visible.length} of ${_results.length} nearby devices'),
            value: _witOnly,
            onChanged: (v) => setState(() => _witOnly = v),
          ),
          const Divider(height: 1),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _startScan,
              child: visible.isEmpty
                  ? ListView(children: [
                      const SizedBox(height: 80),
                      Icon(Icons.bluetooth_searching, size: 64, color: Theme.of(context).colorScheme.outline),
                      const SizedBox(height: 16),
                      Center(
                        child: Text(
                          _scanning ? 'Searching for sensors…' : 'No sensors found.\nPower on the sensor and scan again.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ])
                  : ListView.separated(
                      itemCount: visible.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) => _ResultTile(result: visible[i], onTap: () => _open(visible[i])),
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _adapter != BluetoothAdapterState.on
            ? null
            : (_scanning ? FlutterBluePlus.stopScan : _startScan),
        icon: Icon(_scanning ? Icons.stop : Icons.search),
        label: Text(_scanning ? 'Stop' : 'Scan'),
      ),
    );
  }
}

class _AdapterBanner extends StatelessWidget {
  const _AdapterBanner({required this.state});
  final BluetoothAdapterState state;

  @override
  Widget build(BuildContext context) {
    final canTurnOn = !kIsWeb && Platform.isAndroid && state == BluetoothAdapterState.off;
    return MaterialBanner(
      leading: const Icon(Icons.bluetooth_disabled),
      content: Text(switch (state) {
        BluetoothAdapterState.off => 'Bluetooth is turned off.',
        BluetoothAdapterState.unauthorized => 'Bluetooth permission denied. Enable it in Settings.',
        BluetoothAdapterState.unavailable => 'Bluetooth is not available on this device.',
        _ => 'Waiting for Bluetooth…',
      }),
      actions: [
        if (canTurnOn) TextButton(onPressed: FlutterBluePlus.turnOn, child: const Text('Turn on')) else const SizedBox.shrink(),
      ],
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.result, required this.onTap});
  final ScanResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = result.advertisementData.advName.isNotEmpty
        ? result.advertisementData.advName
        : (result.device.platformName.isNotEmpty ? result.device.platformName : 'Unnamed device');
    final wit = _ScanScreenState.isWitMotion(result);
    return ListTile(
      leading: CircleAvatar(child: Icon(wit ? Icons.sensors : Icons.bluetooth)),
      title: Text(name),
      subtitle: Text(result.device.remoteId.str),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SignalBars(rssi: result.rssi),
          const SizedBox(width: 8),
          Text('${result.rssi} dBm'),
        ],
      ),
      enabled: result.advertisementData.connectable,
      onTap: onTap,
    );
  }
}

class _SignalBars extends StatelessWidget {
  const _SignalBars({required this.rssi});
  final int rssi;

  @override
  Widget build(BuildContext context) {
    final level = rssi >= -60 ? 4 : rssi >= -70 ? 3 : rssi >= -80 ? 2 : 1;
    final on = Theme.of(context).colorScheme.primary;
    final off = Theme.of(context).colorScheme.outlineVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 1; i <= 4; i++)
          Container(
            width: 4,
            height: 4.0 + i * 3,
            margin: const EdgeInsets.only(left: 2),
            color: i <= level ? on : off,
          ),
      ],
    );
  }
}
