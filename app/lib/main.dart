import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';

const String _notifChannelId = 'tracker_foreground';
const int _notifId = 7312;
const String _queueKey = 'pending_locations';
const int _maxQueueSize = 200;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      anonKey: AppConfig.supabaseAnonKey,
    );
  } catch (_) {}

  await _initBackgroundService();
  runApp(const TrackerApp());
}

Future<void> _initBackgroundService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
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

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // Elevate to Android foreground service immediately so the OS doesn't kill it
  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
    service.on('setAsForeground').listen((_) => service.setAsForegroundService());
    service.on('setAsBackground').listen((_) => service.setAsBackgroundService());
  }

  try {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      anonKey: AppConfig.supabaseAnonKey,
    );
  } catch (_) {}

  final prefs = await SharedPreferences.getInstance();
  final deviceId = prefs.getString('device_id') ?? 'unknown';
  final deviceName = prefs.getString('device_name') ?? 'My device';
  final battery = Battery();
  Position? pending;

  final settings = LocationSettings(
    accuracy: LocationAccuracy.medium,
    distanceFilter: AppConfig.minDistanceMeters,
  );
  final sub = Geolocator.getPositionStream(locationSettings: settings).listen(
    (pos) => pending = pos,
    onError: (_) {},
  );

  service.on('stopService').listen((event) async {
    try {
      await sub.cancel();
      await service.stopSelf();
    } catch (_) {}
  });

  // Flush queued offline points.
  Future<void> flushQueue() async {
    final raw = prefs.getStringList(_queueKey) ?? [];
    if (raw.isEmpty) return;
    final failed = <String>[];
    for (final entry in raw) {
      try {
        final map = Map<String, dynamic>.from(jsonDecode(entry) as Map);
        await Supabase.instance.client.from('locations').insert(map);
      } catch (_) {
        failed.add(entry);
      }
    }
    if (failed.isEmpty) {
      await prefs.remove(_queueKey);
    } else {
      await prefs.setStringList(_queueKey, failed);
    }
  }

  Future<void> enqueue(Map<String, dynamic> payload) async {
    try {
      final raw = prefs.getStringList(_queueKey) ?? [];
      if (raw.length >= _maxQueueSize) return;
      raw.add(jsonEncode(payload));
      await prefs.setStringList(_queueKey, raw);
    } catch (_) {}
  }

  Future<void> report() async {
    try {
      if (pending == null) {
        try {
          pending = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.medium,
            timeLimit: const Duration(seconds: 8),
          );
        } catch (_) {
          pending = await Geolocator.getLastKnownPosition();
        }
      }
      final pos = pending;
      if (pos == null) return;

      int? batteryLevel;
      try {
        batteryLevel = await battery.batteryLevel;
      } catch (_) {}

      final nowIso = DateTime.now().toUtc().toIso8601String();
      // GPS speed is m/s; convert to km/h. Negative means unavailable.
      final double? speedKmh = (pos.speed >= 0)
          ? double.parse((pos.speed * 3.6).toStringAsFixed(2))
          : null;

      final devicePayload = <String, dynamic>{
        'device_id': deviceId,
        'name': deviceName,
        'lat': pos.latitude,
        'lng': pos.longitude,
        'battery': batteryLevel,
        'accuracy': pos.accuracy,
        'speed': speedKmh,
        'updated_at': nowIso,
      };

      final locationPayload = <String, dynamic>{
        'device_id': deviceId,
        'lat': pos.latitude,
        'lng': pos.longitude,
        'battery': batteryLevel,
        'accuracy': pos.accuracy,
        'speed': speedKmh,
        'recorded_at': nowIso,
      };

      try {
        await flushQueue();
        await Supabase.instance.client.from('devices').upsert(devicePayload);
        await Supabase.instance.client.from('locations').insert(locationPayload);

        final time = TimeOfDay.fromDateTime(DateTime.now()).format24();
        final speedStr =
            speedKmh != null ? ' · ${speedKmh.toStringAsFixed(1)} km/h' : '';

        if (service is AndroidServiceInstance) {
          service.setForegroundNotificationInfo(
            title: 'Mobile Tracker — sharing location',
            content: 'Last report $time$speedStr',
          );
        }
        service.invoke('update', {
          'lat': pos.latitude,
          'lng': pos.longitude,
          'at': nowIso,
          'battery': batteryLevel,
          'speed': speedKmh,
          'accuracy': pos.accuracy,
        });
      } catch (e) {
        await enqueue(locationPayload);
        service.invoke('update', {'error': e.toString()});
      }

      pending = null;
    } catch (_) {}
  }

  try {
    await report();
  } catch (_) {}

  Timer.periodic(Duration(seconds: AppConfig.reportIntervalSeconds), (_) async {
    try {
      await report();
    } catch (_) {}
  });
}

// ---------------------------------------------------------------------------
//  App root
// ---------------------------------------------------------------------------

class TrackerApp extends StatelessWidget {
  const TrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mobile Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3B82F6), useMaterial3: true),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF3B82F6),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }
}

// ---------------------------------------------------------------------------
//  Home page
// ---------------------------------------------------------------------------

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _service = FlutterBackgroundService();
  final _nameController = TextEditingController();

  bool _tracking = false;
  String _status = 'Checking status…';
  bool _initialized = false;
  String _deviceId = '';
  double? _lastLat;
  double? _lastLng;
  double? _lastSpeed;
  int? _lastBattery;
  double? _lastAccuracy;
  int _pendingCount = 0;

  StreamSubscription<Map<String, dynamic>?>? _updateSub;
  Timer? _statusPollTimer;
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulseAnim = CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut);

    _loadIdentity();
    _syncRunningState();
    _loadPendingCount();

    // Poll service status every 2.5 seconds while UI is open to stay synced
    _statusPollTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      if (mounted) _syncRunningState();
    });

    _updateSub = _service.on('update').listen((event) {
      if (!mounted || event == null) return;
      if (event['error'] != null) {
        _loadPendingCount();
        setState(() => _status = 'Upload failed — saved offline for retry.');
        return;
      }
      setState(() {
        _tracking = true;
        _lastLat = (event['lat'] as num?)?.toDouble();
        _lastLng = (event['lng'] as num?)?.toDouble();
        _lastSpeed = (event['speed'] as num?)?.toDouble();
        _lastBattery = (event['battery'] as num?)?.toInt();
        _lastAccuracy = (event['accuracy'] as num?)?.toDouble();
        _status = 'Reporting every ${AppConfig.reportIntervalSeconds}s when you move.';
      });
      _loadPendingCount();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusPollTimer?.cancel();
    _pulseController.dispose();
    _updateSub?.cancel();
    _nameController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncRunningState();
      _loadPendingCount();
    }
  }

  Future<void> _loadPendingCount() async {
    final prefs = await SharedPreferences.getInstance();
    final count = (prefs.getStringList(_queueKey) ?? []).length;
    if (mounted) setState(() => _pendingCount = count);
  }

  Future<void> _syncRunningState() async {
    final running = await _service.isRunning();
    if (!mounted) return;
    setState(() {
      _tracking = running;
      _initialized = true;
      if (running) {
        if (!_status.startsWith('Reporting') && !_status.startsWith('Tracking')) {
          _status = 'Tracking in the background. Reporting every ${AppConfig.reportIntervalSeconds}s.';
        }
      } else {
        if (_status == 'Checking status…' || _status.startsWith('Tracking') || _status.startsWith('Reporting')) {
          _status = 'Idle. Press Start to begin sharing your location.';
        }
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
    await prefs.setString('device_name', name.isEmpty ? 'My device' : name);
  }

  Future<bool> _ensurePermission() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      setState(() => _status = 'Location services are turned off on this phone.');
      return false;
    }
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      setState(() => _status = 'Location permission denied. Please allow in phone Settings.');
      return false;
    }
    if (perm == LocationPermission.whileInUse) {
      final upgraded = await Geolocator.requestPermission();
      if (upgraded != LocationPermission.always && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Tip: In Settings > Location, set to "Allow all the time" for screen-off tracking.'),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: () => Geolocator.openAppSettings(),
            ),
            duration: const Duration(seconds: 7),
          ),
        );
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
      _status = 'Tracking in the background. Reporting every ${AppConfig.reportIntervalSeconds}s.';
    });
  }

  Future<void> _stop() async {
    _service.invoke('stopService');
    if (!mounted) return;
    setState(() {
      _tracking = false;
      _lastSpeed = null;
      _lastBattery = null;
      _lastAccuracy = null;
      _status = 'Stopped. Your location is no longer being shared.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF161B22) : Colors.white;
    final cardBorder = isDark ? const Color(0xFF2A313B) : Colors.grey.shade200;
    final subtleText = isDark ? Colors.white38 : Colors.black38;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0D1117) : const Color(0xFFF6F8FA),
      appBar: AppBar(
        title: const Text('Mobile Tracker',
            style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.4)),
        centerTitle: false,
        backgroundColor: isDark ? const Color(0xFF161B22) : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1,
              color: isDark ? const Color(0xFF2A313B) : Colors.grey.shade200),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 36),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status card with pulsing glow
            AnimatedBuilder(
              animation: _pulseAnim,
              builder: (_, __) {
                final glowOpacity = _tracking ? _pulseAnim.value * 0.35 : 0.0;
                return Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: _tracking
                          ? (isDark
                              ? [const Color(0xFF0A2218), const Color(0xFF112B1F)]
                              : [const Color(0xFFE8F5E9), const Color(0xFFD0EDD8)])
                          : (isDark
                              ? [const Color(0xFF161B22), const Color(0xFF1C2128)]
                              : [Colors.white, const Color(0xFFF6F8FA)]),
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: _tracking ? Colors.green.withOpacity(0.5) : cardBorder,
                        width: 1.5),
                    boxShadow: _tracking
                        ? [BoxShadow(
                            color: Colors.green.withOpacity(glowOpacity),
                            blurRadius: 24, spreadRadius: 2)]
                        : null,
                  ),
                  child: Row(children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 400),
                      width: 48, height: 48,
                      decoration: BoxDecoration(
                        color: _tracking
                            ? Colors.green.withOpacity(0.15)
                            : Colors.grey.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _tracking ? Icons.location_on_rounded : Icons.location_off_rounded,
                        color: _tracking ? Colors.green : Colors.grey,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _tracking ? 'Live Tracking' : 'Not Tracking',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15,
                              color: _tracking ? Colors.green
                                  : (isDark ? Colors.white60 : Colors.black54)),
                        ),
                        const SizedBox(height: 4),
                        Text(_status,
                            style: TextStyle(fontSize: 12,
                                color: isDark ? Colors.white54 : Colors.black54,
                                height: 1.4)),
                      ],
                    )),
                  ]),
                );
              },
            ),

            // Live metrics (speed / battery / accuracy)
            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              child: _tracking
                  ? Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(children: [
                        _MetricCard(
                          icon: Icons.speed_rounded, label: 'Speed',
                          value: _lastSpeed != null ? _lastSpeed!.toStringAsFixed(1) : '--',
                          unit: _lastSpeed != null ? 'km/h' : '',
                          color: Colors.blue, isDark: isDark,
                        ),
                        const SizedBox(width: 10),
                        _MetricCard(
                          icon: Icons.battery_std_rounded, label: 'Battery',
                          value: _lastBattery != null ? '$_lastBattery' : '--',
                          unit: _lastBattery != null ? '%' : '',
                          color: (_lastBattery != null && _lastBattery! < 20)
                              ? Colors.red : Colors.green,
                          isDark: isDark,
                        ),
                        const SizedBox(width: 10),
                        _MetricCard(
                          icon: Icons.my_location_rounded, label: 'Accuracy',
                          value: _lastAccuracy != null ? _lastAccuracy!.toStringAsFixed(0) : '--',
                          unit: _lastAccuracy != null ? 'm' : '',
                          color: Colors.purple, isDark: isDark,
                        ),
                      ]),
                    )
                  : const SizedBox.shrink(),
            ),

            const SizedBox(height: 16),

            // Offline queue warning
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              child: _pendingCount > 0
                  ? Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.08),
                        border: Border.all(color: Colors.orange.withOpacity(0.35)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(children: [
                        const Icon(Icons.cloud_upload_outlined, color: Colors.orange, size: 18),
                        const SizedBox(width: 10),
                        Expanded(child: Text(
                          '$_pendingCount point${_pendingCount == 1 ? '' : 's'} queued offline — '
                          'will sync automatically when internet returns.',
                          style: const TextStyle(fontSize: 12, color: Colors.orange),
                        )),
                      ]),
                    )
                  : const SizedBox.shrink(),
            ),

            // Device name field
            TextField(
              controller: _nameController,
              enabled: !_tracking,
              style: const TextStyle(fontWeight: FontWeight.w500),
              decoration: InputDecoration(
                labelText: 'Device name',
                hintText: "e.g. Dad's Phone",
                prefixIcon: const Icon(Icons.phone_android_rounded),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true, fillColor: cardBg,
              ),
              onSubmitted: _saveName,
            ),

            const SizedBox(height: 14),

            // Device info card
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: cardBg,
                border: Border.all(color: cardBorder),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(children: [
                _InfoRow(icon: Icons.fingerprint_rounded, label: 'Device ID',
                    value: _deviceId, subtleText: subtleText),
                if (_lastLat != null) ...[
                  Divider(height: 14, color: cardBorder),
                  _InfoRow(icon: Icons.pin_drop_rounded, label: 'Last position',
                      value: '${_lastLat!.toStringAsFixed(5)}, ${_lastLng!.toStringAsFixed(5)}',
                      subtleText: subtleText),
                ],
              ]),
            ),

            const SizedBox(height: 20),

            // Background tip card
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E2530) : const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: isDark ? const Color(0xFF2E3B4E) : const Color(0xFFBFDBFE)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline_rounded, size: 18, color: Color(0xFF3B82F6)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'For 24/7 background tracking: set Location to "Allow all the time" '
                      'and turn off Battery Optimization for Mobile Tracker in Android Settings.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: isDark ? Colors.white70 : const Color(0xFF1E3A8A),
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Start / Stop
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                onPressed: _tracking ? _stop : _start,
                icon: Icon(_tracking ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 22),
                label: Text(_tracking ? 'Stop Tracking' : 'Start Tracking',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                style: FilledButton.styleFrom(
                  backgroundColor: _tracking ? const Color(0xFFB91C1C) : cs.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),

            const SizedBox(height: 18),

            Text(
              "This app shares this phone's location with your dashboard "
              'while tracking is on, even when the screen is off. '
              'Press Stop at any time to revoke access.',
              style: TextStyle(fontSize: 11, color: subtleText, height: 1.5),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon, required this.label, required this.value,
    required this.unit, required this.color, required this.isDark,
  });
  final IconData icon;
  final String label, value, unit;
  final Color color;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF161B22) : Colors.white,
          border: Border.all(color: isDark ? const Color(0xFF2A313B) : Colors.grey.shade200),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 7),
          RichText(
            textAlign: TextAlign.center,
            text: TextSpan(children: [
              TextSpan(text: value,
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: color)),
              if (unit.isNotEmpty)
                TextSpan(text: ' $unit',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 10,
                        color: color.withOpacity(0.7))),
            ]),
          ),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(fontSize: 10,
              color: isDark ? Colors.white38 : Colors.black38)),
        ]),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label,
      required this.value, required this.subtleText});
  final IconData icon;
  final String label, value;
  final Color subtleText;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, size: 14, color: subtleText),
      const SizedBox(width: 8),
      Text('$label: ', style: TextStyle(fontSize: 11, color: subtleText)),
      Expanded(child: Text(value,
          style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis)),
    ]);
  }
}

extension on TimeOfDay {
  String format24() {
    final h = hour.toString().padLeft(2, '0');
    final m = minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
