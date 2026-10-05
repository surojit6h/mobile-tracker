import 'dart:async';
import 'dart:ui';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';

// Android notification channel used by the foreground service. The ongoing
// notification is mandatory for a location foreground service. The plugin
// creates this channel from the AndroidConfiguration below.
const String _notifChannelId = 'tracker_foreground';
const int _notifId = 7312;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
  );

  await _initBackgroundService();

  runApp(const TrackerApp());
}

// ---------------------------------------------------------------------------
//  Background service setup
// ---------------------------------------------------------------------------

Future<void> _initBackgroundService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      // We start manually (only after permission + button press), and the
      // service runs as a foreground service so Android keeps it alive.
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: _notifChannelId,
      initialNotificationTitle: 'Mobile Tracker',
      initialNotificationContent: 'Preparing to share location…',
      foregroundServiceNotificationId: _notifId,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

// iOS background fetch handler. iOS does not support long-running services the
// same way; this returns true so the OS keeps scheduling it. Full iOS
// background tracking would need additional setup, but Android is the target.
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

// This runs in its OWN isolate. It must set up everything it needs from
// scratch: binding, Supabase, and local storage.
@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
  );

  final prefs = await SharedPreferences.getInstance();
  final deviceId = prefs.getString('device_id') ?? 'unknown';
  final deviceName = prefs.getString('device_name') ?? 'My device';

  final battery = Battery();

  Position? pending;

  // Listen to GPS; only keep the latest fix (distance-filtered to save power).
  final settings = LocationSettings(
    accuracy: LocationAccuracy.medium,
    distanceFilter: AppConfig.minDistanceMeters,
  );
  final sub = Geolocator.getPositionStream(locationSettings: settings).listen(
    (pos) => pending = pos,
    onError: (_) {},
  );

  // Allow the UI to stop the service cleanly.
  service.on('stopService').listen((event) async {
    await sub.cancel();
    await service.stopSelf();
  });

  Future<void> report() async {
    // If we have no fresh fix yet, try a last-known one so the first report
    // isn't empty.
    pending ??= await Geolocator.getLastKnownPosition();
    final pos = pending;
    if (pos == null) return;

    int? batteryLevel;
    try {
      batteryLevel = await battery.batteryLevel;
    } catch (_) {
      batteryLevel = null;
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();
    try {
      await Supabase.instance.client.from('devices').upsert({
        'device_id': deviceId,
        'name': deviceName,
        'lat': pos.latitude,
        'lng': pos.longitude,
        'battery': batteryLevel,
        'accuracy': pos.accuracy,
        'updated_at': nowIso,
      });

      await Supabase.instance.client.from('locations').insert({
        'device_id': deviceId,
        'lat': pos.latitude,
        'lng': pos.longitude,
        'battery': batteryLevel,
        'accuracy': pos.accuracy,
        'recorded_at': nowIso,
      });

      final time = TimeOfDay.fromDateTime(DateTime.now()).format24();
      // Update the ongoing foreground-service notification so the user can
      // see it's working. The plugin manages the single ongoing notification.
      if (service is AndroidServiceInstance &&
          await service.isForegroundService()) {
        service.setForegroundNotificationInfo(
          title: 'Mobile Tracker — sharing location',
          content: 'Last report $time '
              '(${pos.latitude.toStringAsFixed(4)}, '
              '${pos.longitude.toStringAsFixed(4)})',
        );
      }
      // Tell the UI (if open) about the latest report.
      service.invoke('update', {
        'lat': pos.latitude,
        'lng': pos.longitude,
        'at': nowIso,
        'battery': batteryLevel,
      });
    } catch (e) {
      service.invoke('update', {'error': e.toString()});
    }

    pending = null; // avoid re-sending the same point
  }

  // One report right away, then on the interval.
  await report();
  Timer.periodic(
    Duration(seconds: AppConfig.reportIntervalSeconds),
    (_) => report(),
  );
}

// ---------------------------------------------------------------------------
//  UI
// ---------------------------------------------------------------------------

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
  final _service = FlutterBackgroundService();
  final _nameController = TextEditingController();

  bool _tracking = false;
  String _status = 'Idle. Press Start to begin sharing your location.';
  String _deviceId = '';
  double? _lastLat;
  double? _lastLng;
  StreamSubscription<Map<String, dynamic>?>? _updateSub;

  @override
  void initState() {
    super.initState();
    _loadIdentity();
    _syncRunningState();

    // Receive live updates from the background service while the UI is open.
    _updateSub = _service.on('update').listen((event) {
      if (!mounted || event == null) return;
      if (event['error'] != null) {
        setState(() => _status = 'Upload failed: ${event['error']}');
        return;
      }
      setState(() {
        _lastLat = (event['lat'] as num?)?.toDouble();
        _lastLng = (event['lng'] as num?)?.toDouble();
        _status = 'Last report sent '
            '(${_lastLat?.toStringAsFixed(5)}, '
            '${_lastLng?.toStringAsFixed(5)})';
      });
    });
  }

  @override
  void dispose() {
    _updateSub?.cancel();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _syncRunningState() async {
    final running = await _service.isRunning();
    if (!mounted) return;
    setState(() {
      _tracking = running;
      if (running) {
        _status = 'Tracking in the background. Reporting every '
            '${AppConfig.reportIntervalSeconds}s when you move.';
      }
    });
  }

  Future<void> _loadIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('device_id');
    if (id == null) {
      id = 'dev_${DateTime.now().millisecondsSinceEpoch}';
      await prefs.setString('device_id', id);
    }
    final name = prefs.getString('device_name') ?? 'My device';
    if (!mounted) return;
    setState(() {
      _deviceId = id!;
      _nameController.text = name;
    });
  }

  Future<void> _saveName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'device_name', name.isEmpty ? 'My device' : name);
  }

  // Requests location permission, escalating to "always" (background), which
  // is required to keep tracking with the screen off.
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

    // "whileInUse" works in the foreground, but for reliable background
    // tracking Android needs "always" (Allow all the time). Request the
    // upgrade; if the user declines we still start, but warn them.
    if (perm == LocationPermission.whileInUse) {
      final upgraded = await Geolocator.requestPermission();
      if (upgraded != LocationPermission.always) {
        setState(() => _status =
            'Tip: set location to "Allow all the time" so tracking keeps '
            'working when the screen is off.');
      }
    }
    return true;
  }

  Future<void> _start() async {
    final ok = await _ensurePermission();
    if (!ok) return;

    await _saveName(_nameController.text.trim());

    await _service.startService();

    if (!mounted) return;
    setState(() {
      _tracking = true;
      _status = 'Tracking in the background. Reporting every '
          '${AppConfig.reportIntervalSeconds}s when you move.';
    });
  }

  Future<void> _stop() async {
    _service.invoke('stopService');
    if (!mounted) return;
    setState(() {
      _tracking = false;
      _status = 'Stopped. Your location is no longer being shared.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final lastText = (_lastLat == null || _lastLng == null)
        ? '—'
        : '${_lastLat!.toStringAsFixed(5)}, ${_lastLng!.toStringAsFixed(5)}';

    return Scaffold(
      appBar: AppBar(title: const Text('Mobile Tracker')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'This app shares this phone\'s location with your dashboard '
              'while tracking is on, even when the screen is off. '
              'Press Stop any time.',
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
                color: _tracking
                    ? const Color(0xFFE8F5E9)
                    : const Color(0xFFF1F3F4),
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

// Small helper for a 24h HH:mm string without pulling in intl.
extension on TimeOfDay {
  String format24() {
    final h = hour.toString().padLeft(2, '0');
    final m = minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
