import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
  );

  runApp(const TrackerApp());
}

class TrackerApp extends StatelessWidget {
  const TrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mobile Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3B82F6),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _battery = Battery();
  final _nameController = TextEditingController();

  bool _tracking = false;
  String _status = 'Idle. Press Start to begin sharing your location.';
  String _deviceId = '';
  Position? _lastPosition;
  StreamSubscription<Position>? _positionSub;
  Timer? _reportTimer;
  Position? _pendingPosition;

  @override
  void initState() {
    super.initState();
    _loadIdentity();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _reportTimer?.cancel();
    _nameController.dispose();
    super.dispose();
  }

  // A stable, random device id stored on the phone.
  Future<void> _loadIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('device_id');
    if (id == null) {
      id = 'dev_${DateTime.now().millisecondsSinceEpoch}';
      await prefs.setString('device_id', id);
    }
    final name = prefs.getString('device_name') ?? 'My device';
    setState(() {
      _deviceId = id!;
      _nameController.text = name;
    });
  }

  Future<void> _saveName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_name', name);
  }

  Future<bool> _ensurePermission() async {
    bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      setState(() => _status = 'Location services are turned off on this phone.');
      return false;
    }

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      setState(() => _status = 'Location permission denied.');
      return false;
    }
    return true;
  }

  Future<void> _start() async {
    final ok = await _ensurePermission();
    if (!ok) return;

    await _saveName(_nameController.text.trim());

    // Battery-friendly settings: medium accuracy + distance filter so the
    // phone only wakes up the GPS when it has actually moved.
    final settings = LocationSettings(
      accuracy: LocationAccuracy.medium,
      distanceFilter: AppConfig.minDistanceMeters,
    );

    _positionSub =
        Geolocator.getPositionStream(locationSettings: settings).listen(
      (pos) {
        _pendingPosition = pos;
        _lastPosition = pos;
      },
      onError: (e) {
        setState(() => _status = 'Location error: $e');
      },
    );

    // Only actually upload on an interval, not on every GPS tick. This caps
    // network use and is much kinder to the battery.
    _reportTimer = Timer.periodic(
      Duration(seconds: AppConfig.reportIntervalSeconds),
      (_) => _report(),
    );

    // Send one point right away so the dashboard shows the device fast.
    // getLastKnownPosition() takes no settings and is stable across
    // geolocator versions. If there's no cached fix yet, the position
    // stream above will deliver the first real fix within a few seconds.
    final first = await Geolocator.getLastKnownPosition();
    if (first != null) {
      _pendingPosition = first;
      _lastPosition = first;
      await _report();
    }

    setState(() {
      _tracking = true;
      _status = 'Tracking. Reporting every '
          '${AppConfig.reportIntervalSeconds}s when you move.';
    });
  }

  Future<void> _stop() async {
    await _positionSub?.cancel();
    _reportTimer?.cancel();
    _positionSub = null;
    _reportTimer = null;
    setState(() {
      _tracking = false;
      _status = 'Stopped. Your location is no longer being shared.';
    });
  }

  Future<void> _report() async {
    final pos = _pendingPosition;
    if (pos == null) return;

    int? batteryLevel;
    try {
      batteryLevel = await _battery.batteryLevel;
    } catch (_) {
      batteryLevel = null;
    }

    try {
      await Supabase.instance.client.from('devices').upsert({
        'device_id': _deviceId,
        'name': _nameController.text.trim().isEmpty
            ? 'My device'
            : _nameController.text.trim(),
        'lat': pos.latitude,
        'lng': pos.longitude,
        'battery': batteryLevel,
        'accuracy': pos.accuracy,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      setState(() {
        _status = 'Last report: ${TimeOfDay.now().format(context)} '
            '(${pos.latitude.toStringAsFixed(5)}, '
            '${pos.longitude.toStringAsFixed(5)})';
      });
    } catch (e) {
      setState(() => _status = 'Upload failed: $e');
    }
    _pendingPosition = null; // avoid re-sending the same point
  }

  @override
  Widget build(BuildContext context) {
    final lastText = _lastPosition == null
        ? '—'
        : '${_lastPosition!.latitude.toStringAsFixed(5)}, '
            '${_lastPosition!.longitude.toStringAsFixed(5)}';

    return Scaffold(
      appBar: AppBar(title: const Text('Mobile Tracker')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'This app shares this phone\'s location with your dashboard '
              'while tracking is on. Press Stop any time.',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _nameController,
              enabled: !_tracking,
              decoration: const InputDecoration(
                labelText: 'Device name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _tracking ? const Color(0xFFE8F5E9) : const Color(0xFFF1F3F4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    _tracking ? Icons.location_on : Icons.location_off,
                    color: _tracking ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_status)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text('Device ID: $_deviceId',
                style: const TextStyle(fontSize: 12, color: Colors.black45)),
            Text('Last position: $lastText',
                style: const TextStyle(fontSize: 12, color: Colors.black45)),
            const Spacer(),
            SizedBox(
              height: 54,
              child: FilledButton.icon(
                onPressed: _tracking ? _stop : _start,
                icon: Icon(_tracking ? Icons.stop : Icons.play_arrow),
                label: Text(_tracking ? 'Stop tracking' : 'Start tracking'),
                style: FilledButton.styleFrom(
                  backgroundColor: _tracking ? Colors.red : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
