import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart';
import 'package:kakao_maps_flutter/kakao_maps_flutter.dart';
import 'package:local_auth/local_auth.dart';
import 'package:photo_manager/photo_manager.dart' hide LatLng;
import 'package:shared_preferences/shared_preferences.dart';

import 'data/trip_store.dart';
import 'config/app_config.dart';
import 'models/trip.dart';
import 'services/location_service.dart';
import 'services/weather_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppConfig.load();
  await KakaoMapsFlutter.init(AppConfig.kakaoNativeAppKey);
  runApp(TravelRecordApp(store: await TripStore.load()));
}

class TravelRecordApp extends StatefulWidget {
  const TravelRecordApp({
    super.key,
    required this.store,
    this.requireAuth = true,
    this.requestPermissions = true,
  });

  final TripStore store;
  final bool requireAuth;
  final bool requestPermissions;

  @override
  State<TravelRecordApp> createState() => _TravelRecordAppState();
}

class _TravelRecordAppState extends State<TravelRecordApp>
    with WidgetsBindingObserver {
  static const _reauthenticationInterval = Duration(minutes: 10);
  DateTime? _backgroundAt;
  bool _unlocked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgroundAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final backgroundAt = _backgroundAt;
      _backgroundAt = null;
      if (backgroundAt != null &&
          DateTime.now().difference(backgroundAt) >=
              _reauthenticationInterval &&
          mounted) {
        setState(() => _unlocked = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '여행기록',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff102a56)),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xfff6f8fc),
      ),
      home: widget.requireAuth && !_unlocked
          ? AuthPage(
              store: widget.store,
              requestPermissions: widget.requestPermissions,
              onAuthenticated: () => setState(() => _unlocked = true),
            )
          : TripListPage(
              store: widget.store,
              requestPermissions: widget.requestPermissions,
            ),
    );
  }
}

class AuthPage extends StatefulWidget {
  const AuthPage({
    super.key,
    required this.store,
    required this.requestPermissions,
    required this.onAuthenticated,
  });

  final TripStore store;
  final bool requestPermissions;
  final VoidCallback onAuthenticated;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _auth = LocalAuthentication();
  bool _busy = false;
  String? _error;

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final authenticated = await _auth.authenticate(
        localizedReason: '여행기록을 열려면 기기 인증이 필요합니다.',
        persistAcrossBackgrounding: true,
      );
      if (!mounted) return;
      if (authenticated) {
        widget.onAuthenticated();
      }
    } on LocalAuthException catch (error) {
      if (mounted) setState(() => _error = '인증을 완료할 수 없습니다: ${error.code}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.luggage_outlined, size: 64),
                const SizedBox(height: 20),
                Text('여행기록', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                const Text('기기에 저장된 여행 자료를 보호합니다.'),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: _busy ? null : _unlock,
                  icon: const Icon(Icons.fingerprint),
                  label: Text(_busy ? '인증 중...' : '잠금 해제'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TripListPage extends StatefulWidget {
  const TripListPage({
    super.key,
    required this.store,
    this.requestPermissions = true,
  });

  final TripStore store;
  final bool requestPermissions;

  @override
  State<TripListPage> createState() => _TripListPageState();
}

class _TripListPageState extends State<TripListPage>
    with SingleTickerProviderStateMixin {
  List<Trip> _trips = [];
  bool _loading = true;
  late final AnimationController _activeIndicator;
  final _locationService = LocationService();

  @override
  void initState() {
    super.initState();
    _activeIndicator = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
      lowerBound: 0.25,
      upperBound: 1,
    );
    _loadTrips();
    if (widget.requestPermissions) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _requestPermissions(),
      );
    }
  }

  void _updateActiveIndicator() {
    if (_trips.any(_isTripActive)) {
      _activeIndicator.repeat(reverse: true);
    } else {
      _activeIndicator.stop();
    }
  }

  Future<void> _loadTrips() async {
    final trips = await widget.store.readAll();
    if (!mounted) return;
    setState(() {
      _trips = trips;
      _loading = false;
    });
    _updateActiveIndicator();
    if (widget.requestPermissions) {
      _startAutomaticCollection();
    }
  }

  @override
  void dispose() {
    _activeIndicator.dispose();
    _locationService.dispose();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    final preferences = SharedPreferencesAsync();
    if (await preferences.getBool('permission_prompted') == true) {
      await _startAutomaticCollection();
      return;
    }
    await preferences.setBool('permission_prompted', true);
    if (!mounted) return;

    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('여행기록 권한 안내'),
        content: const Text(
          '여행 기간 동안 5분 간격으로 위치를 자동 저장합니다. '
          '백그라운드에서도 수집하려면 위치와 알림 권한이 필요합니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('나중에'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('권한 허용'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;

    try {
      await _locationService.ensurePermission();
      await const MethodChannel('travel_record/permissions')
          .invokeMethod<void>('requestNotifications');
      await _startAutomaticCollection();
    } on MissingPluginException {
      await _startAutomaticCollection();
    } on LocationException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _startAutomaticCollection() async {
    final preferences = SharedPreferencesAsync();
    final enabled =
        await preferences.getBool('location_collection_enabled') ?? true;
    final background =
        await preferences.getBool('background_location_enabled') ?? false;
    final activeTrips = _trips.where(_isTripActive).toList();
    if (!enabled || activeTrips.isEmpty) {
      await _locationService.stopAutomaticCollection();
      return;
    }
    final trip = activeTrips.first;
    try {
      await _locationService.startAutomaticCollection(
        onLocation: (location) => _saveAutomaticLocation(trip.id, location),
        background: background,
      );
    } on LocationException {
      // 권한 안내에서 거부한 경우에는 수동 위치 기록만 유지합니다.
    }
  }

  Future<void> _saveAutomaticLocation(
    String tripId,
    RouteLocation location,
  ) async {
    final index = _trips.indexWhere((trip) => trip.id == tripId);
    if (index == -1) return;
    final trip = _trips[index].copyWith(
      routePoints: [
        ..._trips[index].routePoints,
        RoutePoint(
          recordedAt: DateTime.now(),
          latitude: location.latitude,
          longitude: location.longitude,
          accuracy: location.accuracy,
        ),
      ],
    );
    await widget.store.save(trip);
    if (!mounted) return;
    setState(() => _trips[index] = trip);
  }

  Future<void> _createTrip() async {
    final trip = await showDialog<Trip>(
      context: context,
      builder: (_) => const CreateTripDialog(),
    );
    if (trip == null) return;
    await widget.store.save(trip);
    if (mounted) {
      setState(() => _trips = [..._trips, trip]);
      _updateActiveIndicator();
      await _startAutomaticCollection();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeTrips = _trips.where(_isTripActive).toList();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: Colors.white,
        title: const Text(
          '여행기록',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            onPressed: () {},
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: '내 정보',
          ),
          IconButton(
            onPressed: () async {
              await Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
              await _startAutomaticCollection();
            },
            icon: const Icon(Icons.settings_outlined),
            tooltip: '설정',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.zero,
              children: [
                Container(
                  color: theme.colorScheme.primary,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        activeTrips.isEmpty ? '새로운 여행을 준비해보세요' : '여행 중인 기록',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        activeTrips.isEmpty
                            ? '나만의 여행을\n기록해보세요'
                            : '${activeTrips.first.regionName}\n여행을 기록하고 있어요',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          height: 1.2,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.explore_outlined,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                activeTrips.isEmpty
                                    ? '여행을 만들고 기록을 시작하세요'
                                    : '${_date(activeTrips.first.startDate)} ~ ${_date(activeTrips.first.endDate)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.chevron_right,
                              color: theme.colorScheme.primary,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
                  child: Row(
                    children: [
                      _DashboardAction(
                        icon: Icons.add_location_alt_outlined,
                        label: '여행 만들기',
                        onTap: _createTrip,
                      ),
                      _DashboardAction(
                        icon: Icons.photo_library_outlined,
                        label: '사진 기록',
                        onTap: activeTrips.isEmpty
                            ? null
                            : () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => PhotoGalleryPage(
                                    store: widget.store,
                                    trip: activeTrips.first,
                                  ),
                                ),
                              ),
                      ),
                      _DashboardAction(
                        icon: Icons.settings_outlined,
                        label: '앱 설정',
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const SettingsPage(),
                            ),
                          );
                          await _startAutomaticCollection();
                        },
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
                  child: Text(
                    '나의 여행',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (_trips.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('아직 여행이 없습니다.'),
                  )
                else
                  ..._trips.map(_buildTripCard),
                const SizedBox(height: 96),
              ],
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        onDestinationSelected: (index) async {
          if (index == 2) {
            await Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SettingsPage()));
            await _startAutomaticCollection();
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '홈',
          ),
          NavigationDestination(
            icon: Icon(Icons.luggage_outlined),
            label: '여행',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: '내 정보',
          ),
        ],
      ),
    );
  }

  Widget _buildTripCard(Trip trip) {
    final theme = Theme.of(context);
    final active = _isTripActive(trip);
    final icon = trip.regionType == 'domestic'
        ? Icons.location_city
        : Icons.public;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TripDetailPage(store: widget.store, trip: trip),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                active
                    ? AnimatedBuilder(
                        animation: _activeIndicator,
                        builder: (context, child) => CircleAvatar(
                          backgroundColor: Color.lerp(
                            theme.colorScheme.primaryContainer,
                            Colors.green,
                            _activeIndicator.value,
                          ),
                          child: Icon(icon, color: Colors.white),
                        ),
                      )
                    : CircleAvatar(
                        backgroundColor: theme.colorScheme.primaryContainer,
                        child: Icon(icon, color: theme.colorScheme.primary),
                      ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _tripLocation(trip),
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_date(trip.startDate)} ~ ${_date(trip.endDate)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DashboardAction extends StatelessWidget {
  const _DashboardAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = onTap == null
        ? Theme.of(context).disabledColor
        : Theme.of(context).colorScheme.primary;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              CircleAvatar(
                radius: 25,
                backgroundColor: color.withValues(alpha: 0.1),
                child: Icon(icon, color: color),
              ),
              const SizedBox(height: 8),
              Text(label, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

class CreateTripDialog extends StatefulWidget {
  const CreateTripDialog({super.key});

  @override
  State<CreateTripDialog> createState() => _CreateTripDialogState();
}

class _CreateTripDialogState extends State<CreateTripDialog> {
  final _name = TextEditingController();
  final _country = TextEditingController();
  String _regionType = 'domestic';
  DateTime? _start;
  DateTime? _end;
  String? _error;

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDateRange: _start != null && _end != null
          ? DateTimeRange(start: _start!, end: _end!)
          : null,
    );
    if (picked != null) {
      setState(() {
        _start = picked.start;
        _end = picked.end;
      });
    }
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '도시 또는 나라를 입력하세요.');
      return;
    }
    if (_start == null || _end == null) {
      setState(() => _error = '시작일과 종료일을 선택하세요.');
      return;
    }
    if (_end!.isBefore(_start!)) {
      setState(() => _error = '종료일은 시작일 이후여야 합니다.');
      return;
    }
    Navigator.of(context).pop(
      Trip(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        regionType: _regionType,
        regionName: name,
        startDate: _start!,
        endDate: _end!,
        countryName: _regionType == 'domestic'
            ? '대한민국'
            : (_country.text.trim().isEmpty ? null : _country.text.trim()),
      ),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _country.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('새 여행 만들기'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              value: _regionType,
              decoration: const InputDecoration(labelText: '여행 구분'),
              items: const [
                DropdownMenuItem(value: 'domestic', child: Text('국내 · 도시')),
                DropdownMenuItem(value: 'overseas', child: Text('해외 · 도시')),
              ],
              onChanged: (value) => setState(() => _regionType = value!),
            ),
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: _regionType == 'domestic' ? '도시' : '도시',
              ),
            ),
            if (_regionType == 'overseas')
              TextField(
                controller: _country,
                decoration: const InputDecoration(labelText: '국가명(영문 권장)'),
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                _start == null || _end == null
                    ? '일정 선택'
                    : '${_date(_start!)} ~ ${_date(_end!)}',
              ),
              trailing: const Icon(Icons.calendar_month_outlined),
              onTap: _pickDateRange,
            ),
            if (_error != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _save, child: const Text('저장')),
      ],
    );
  }
}

class TripDetailPage extends StatefulWidget {
  const TripDetailPage({super.key, required this.store, required this.trip});

  final TripStore store;
  final Trip trip;

  @override
  State<TripDetailPage> createState() => _TripDetailPageState();
}

class _TripDetailPageState extends State<TripDetailPage> {
  final _locationService = LocationService();
  final _weatherService = WeatherService();
  late Trip _trip;
  bool _loading = false;
  String _weatherStatus = '날씨 정보를 불러오는 중...';
  bool _selectionMode = false;
  final Set<String> _selectedRecordIds = {};

  @override
  void initState() {
    super.initState();
    _trip = widget.trip;
    _loadLatestTrip().then((_) => _loadWeather());
  }

  Future<void> _loadLatestTrip() async {
    final trips = await widget.store.readAll();
    final latest = trips.where((trip) => trip.id == widget.trip.id).firstOrNull;
    if (latest != null && mounted) setState(() => _trip = latest);
  }

  Future<void> _loadWeather() async {
    final targetDate = _weatherTargetDate;
    final stored = _trip.weatherRecords.where(
      (record) => _dateOnly(record.date) == targetDate,
    );
    final today = _dateOnly(DateTime.now());
    if (stored.isNotEmpty && today.isAfter(targetDate)) {
      _weatherStatus = stored.first.summary;
      return;
    }
    if (today.isAfter(targetDate)) {
      _weatherStatus = '저장된 해당 여행일 날씨가 없습니다.';
      return;
    }
    if (_trip.weatherSummary != null &&
        _trip.weatherDate != null &&
        _dateOnly(_trip.weatherDate!) == targetDate) {
      _weatherStatus = _trip.weatherSummary!;
      return;
    }
    try {
      final record = await _weatherService.fetchRecord(_trip, date: targetDate);
      if (record == null) {
        if (mounted) {
          setState(() => _weatherStatus = '해당 여행일의 WWIS 날씨 정보가 없습니다.');
        }
        return;
      }
      final records = [
        ..._trip.weatherRecords.where(
          (item) => _dateOnly(item.date) != targetDate,
        ),
        record,
      ];
      final updated = _trip.copyWith(
        weatherSummary: record.summary,
        weatherDate: targetDate,
        weatherRecords: records,
      );
      await widget.store.save(updated);
      if (mounted) setState(() => _trip = updated);
    } on WeatherException catch (error) {
      if (mounted) setState(() => _weatherStatus = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _weatherStatus = '날씨 서버에 연결하지 못했습니다.');
      }
    }
  }

  String get _weatherText {
    final targetDate = _weatherTargetDate;
    final record = _trip.weatherRecords.where(
      (item) => _dateOnly(item.date) == targetDate,
    );
    if (record.isNotEmpty) return record.first.summary;
    if (_trip.weatherSummary != null &&
        _trip.weatherDate != null &&
        _dateOnly(_trip.weatherDate!) == targetDate) {
      return _trip.weatherSummary!;
    }
    return _weatherStatus;
  }

  DateTime get _weatherTargetDate {
    final today = _dateOnly(DateTime.now());
    final start = _dateOnly(_trip.startDate);
    final end = _dateOnly(_trip.endDate);
    if (!today.isBefore(start) && !today.isAfter(end)) return today;
    return today.isBefore(start) ? start : end;
  }

  String get _weatherBackground {
    final text = _weatherText.toLowerCase();
    if (text.contains('비') ||
        text.contains('rain') ||
        text.contains('thunder') ||
        text.contains('storm')) {
      return 'assets/weather/rainy-sky.png';
    }
    if (text.contains('흐림') ||
        text.contains('구름') ||
        text.contains('cloud') ||
        text.contains('overcast')) {
      return 'assets/weather/overcast-sky.png';
    }
    return 'assets/weather/clear-sky.png';
  }

  WeatherRecord? get _weatherRecord {
    final targetDate = _weatherTargetDate;
    for (final record in _trip.weatherRecords) {
      if (_dateOnly(record.date) == targetDate) return record;
    }
    return null;
  }

  String get _weatherDateLabel {
    const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    final date = _weatherTargetDate;
    return '${date.month}/${date.day} ${weekdays[date.weekday - 1]}';
  }

  IconData get _weatherIcon {
    final text = _weatherText.toLowerCase();
    if (text.contains('비') || text.contains('rain')) return Icons.umbrella;
    if (text.contains('눈') || text.contains('snow')) return Icons.ac_unit;
    if (text.contains('흐림') ||
        text.contains('구름') ||
        text.contains('cloud') ||
        text.contains('overcast')) {
      return Icons.cloud_outlined;
    }
    return Icons.wb_sunny_outlined;
  }

  Future<void> _recordLocation() async {
    setState(() => _loading = true);
    try {
      final location = await _locationService.currentLocation();
      _trip = _trip.copyWith(
        routePoints: [
          ..._trip.routePoints,
          RoutePoint(
            recordedAt: DateTime.now(),
            latitude: location.latitude,
            longitude: location.longitude,
            accuracy: location.accuracy,
          ),
        ],
      );
      await widget.store.save(_trip);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('현재 위치를 저장했습니다.')));
      }
    } on LocationException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('위치를 가져오지 못했습니다.')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startSelection() => setState(() {
    _selectionMode = true;
    _selectedRecordIds.clear();
  });

  void _toggleRecord(String id) => setState(() {
    if (!_selectedRecordIds.add(id)) _selectedRecordIds.remove(id);
  });

  Future<void> _deleteSelectedRecords() async {
    if (_selectedRecordIds.isEmpty) return;
    final hidden = {..._trip.hiddenPhotoIds, ..._selectedRecordIds};
    _trip = _trip.copyWith(
      hiddenPhotoIds: hidden.toList(),
      photoMetadata: _trip.photoMetadata
          .where((photo) => !hidden.contains(photo.assetId))
          .toList(),
    );
    await widget.store.save(_trip);
    if (!mounted) return;
    setState(() {
      _selectedRecordIds.clear();
      _selectionMode = false;
    });
  }

  Future<void> _editSelectedRecord() async {
    if (_selectedRecordIds.length != 1) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('수정할 사진 기록을 하나만 선택해주세요.')));
      return;
    }
    final id = _selectedRecordIds.single;
    final index = _trip.photoMetadata.indexWhere(
      (photo) => photo.assetId == id,
    );
    if (index < 0) return;
    final photo = _trip.photoMetadata[index];
    await _editPhoto(photo);
  }

  Future<void> _editPhoto(PhotoMetadata photo) async {
    final index = _trip.photoMetadata.indexWhere(
      (item) => item.assetId == photo.assetId,
    );
    if (index < 0) return;
    final memo = await showDialog<String>(
      context: context,
      builder: (_) => _EditMemoDialog(initialMemo: photo.memo),
    );
    if (memo == null) return;
    final updated = [..._trip.photoMetadata];
    updated[index] = PhotoMetadata(
      assetId: photo.assetId,
      capturedAt: photo.capturedAt,
      filePath: photo.filePath,
      memo: memo,
      latitude: photo.latitude,
      longitude: photo.longitude,
    );
    _trip = _trip.copyWith(photoMetadata: updated);
    await widget.store.save(_trip);
    if (mounted) setState(() {});
  }

  Future<void> _deletePhoto(String assetId) async {
    _trip = _trip.copyWith(
      hiddenPhotoIds: {..._trip.hiddenPhotoIds, assetId}.toList(),
      photoMetadata: _trip.photoMetadata
          .where((photo) => photo.assetId != assetId)
          .toList(),
    );
    await widget.store.save(_trip);
    if (mounted) setState(() {});
  }

  Future<void> _showRecordActions(_TimelineEntry entry) async {
    if (entry.photo == null) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(entry.title),
          content: Text(entry.detail),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('닫기'),
            ),
          ],
        ),
      );
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('메모 수정/추가'),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('항목 삭제'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'edit') await _editPhoto(entry.photo!);
    if (action == 'delete') await _deletePhoto(entry.photo!.assetId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_trip.regionName),
        actions: [
          if (_selectionMode) ...[
            IconButton(
              onPressed: _editSelectedRecord,
              icon: const Icon(Icons.edit_outlined),
              tooltip: '선택 항목 수정',
            ),
            IconButton(
              onPressed: _deleteSelectedRecords,
              icon: const Icon(Icons.delete_outline),
              tooltip: '선택 항목 삭제',
            ),
            IconButton(
              onPressed: () => setState(() {
                _selectionMode = false;
                _selectedRecordIds.clear();
              }),
              icon: const Icon(Icons.close),
              tooltip: '선택 취소',
            ),
          ] else
            IconButton(
              onPressed: _startSelection,
              icon: const Icon(Icons.more_horiz),
              tooltip: '여행 메뉴',
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              '${_tripLocation(_trip)}  ${_date(_trip.startDate)} ~ ${_date(_trip.endDate)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700, fontSize: 16),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TripMap(trip: _trip),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Row(
              children: [
                Text(
                  '여행 기록',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _openPhotoGallery,
                  child: const Text('편집'),
                ),
              ],
            ),
          ),
          Expanded(child: _buildRecordList()),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _recordLocation,
        icon: const Icon(Icons.my_location),
        label: Text(_loading ? '위치 확인 중' : '현재 위치 기록'),
      ),
    );
  }

  Future<void> _openPhotoGallery() async {
    final updated = await Navigator.of(context).push<Trip>(
      MaterialPageRoute(
        builder: (_) => PhotoGalleryPage(store: widget.store, trip: _trip),
      ),
    );
    if (updated != null && mounted) setState(() => _trip = updated);
  }

  Widget _buildRecordList() {
    final entries = <_TimelineEntry>[];
    final points = [..._trip.routePoints]
      ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
    if (points.isNotEmpty) {
      final first = points.first;
      final last = points.last;
      entries.add(
        _TimelineEntry(
          time: first.recordedAt,
          title: '시작 위치',
          detail: _coordinate(first.latitude, first.longitude),
          icon: Icons.trip_origin,
        ),
      );
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      if (today.isAfter(_dateOnly(_trip.endDate))) {
        entries.add(
          _TimelineEntry(
            time: last.recordedAt,
            title: '종료 위치',
            detail: _coordinate(last.latitude, last.longitude),
            icon: Icons.flag_outlined,
          ),
        );
      }
    }
    for (final photo in _trip.photoMetadata) {
      final place = photo.latitude == null
        ? '장소 정보 없음'
        : _coordinate(photo.latitude!, photo.longitude!);
      final memo = photo.memo?.trim();
      final hasMemo = memo != null && memo.isNotEmpty;
      entries.add(
        _TimelineEntry(
          time: photo.capturedAt,
          title: '사진/동영상',
          detail: hasMemo
              ? memo
              : '${_dateTime(photo.capturedAt)} · $place\n${photo.filePath}',
          icon: Icons.photo_outlined,
          id: photo.assetId,
          photo: photo,
        ),
      );
    }
    entries.add(
      _TimelineEntry(
        time: _weatherTargetDate,
        title: '날씨',
        detail: _weatherText,
        icon: Icons.cloud_outlined,
      ),
    );
    entries.sort((a, b) {
      if (a.title == '날씨') return -1;
      if (b.title == '날씨') return 1;
      return a.time.compareTo(b.time);
    });
    var sequence = 0;
    for (var index = 0; index < entries.length; index++) {
      if (entries[index].title != '날씨') {
        sequence++;
        entries[index] = entries[index].copyWith(sequence: sequence);
      }
    }
    if (entries.isEmpty) {
      return const Center(child: Text('저장된 여행 기록이 없습니다.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final selected =
            entry.id != null && _selectedRecordIds.contains(entry.id);
        if (entry.title == '날씨') return _buildWeatherRecordCard();
        return Card(
          margin: EdgeInsets.zero,
          child: InkWell(
            onTap: _selectionMode
                ? (entry.id == null ? null : () => _toggleRecord(entry.id!))
                : () => _showRecordActions(entry),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 56,
                    height: 44,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(child: _thumbnail(entry)),
                        if (entry.sequence != null)
                          Positioned(
                            left: -2,
                            top: -2,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 1,
                                ),
                                child: Text(
                                  '(${entry.sequence})',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                entry.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _shortDateTime(entry.time),
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: Colors.black45),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          entry.detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (_selectionMode && entry.id != null)
                    Checkbox(
                      value: selected,
                      onChanged: (_) => _toggleRecord(entry.id!),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildWeatherRecordCard() => Card(
    margin: EdgeInsets.zero,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 76,
        decoration: BoxDecoration(
          image: DecorationImage(
            image: AssetImage(_weatherBackground),
            fit: BoxFit.cover,
          ),
        ),
        child: Container(
          color: Colors.black26,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _weatherDateLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(_weatherIcon, color: Colors.white, size: 34),
              const SizedBox(width: 20),
              Text(
                _weatherRecord?.maximumTemperature == null
                    ? '--°'
                    : '${_weatherRecord!.maximumTemperature!.toStringAsFixed(0)}°',
                style: const TextStyle(color: Colors.white, fontSize: 20),
              ),
              const SizedBox(width: 20),
              Text(
                _weatherRecord?.minimumTemperature == null
                    ? '--°'
                    : '${_weatherRecord!.minimumTemperature!.toStringAsFixed(0)}°',
                style: const TextStyle(color: Color(0xffb9d8f2), fontSize: 20),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _thumbnail(_TimelineEntry entry) {
    final photo = entry.photo;
    if (photo == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(entry.icon),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: FutureBuilder<AssetEntity?>(
        future: AssetEntity.fromId(photo.assetId),
        builder: (context, assetSnapshot) {
          final asset = assetSnapshot.data;
          if (asset == null) return const ColoredBox(color: Colors.black12);
          return FutureBuilder<Uint8List?>(
            future: asset.thumbnailDataWithSize(
              const ThumbnailSize.square(240),
            ),
            builder: (context, snapshot) => snapshot.hasData
                ? Image.memory(snapshot.data!, fit: BoxFit.cover)
                : const ColoredBox(color: Colors.black12),
          );
        },
      ),
    );
  }

  String _coordinate(double latitude, double longitude) =>
      '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}';
}

class _TimelineEntry {
  const _TimelineEntry({
    required this.time,
    required this.title,
    required this.detail,
    required this.icon,
    this.id,
    this.photo,
    this.sequence,
  });

  final DateTime time;
  final String title;
  final String detail;
  final IconData icon;
  final String? id;
  final PhotoMetadata? photo;
  final int? sequence;

  _TimelineEntry copyWith({int? sequence}) => _TimelineEntry(
    time: time,
    title: title,
    detail: detail,
    icon: icon,
    id: id,
    photo: photo,
    sequence: sequence ?? this.sequence,
  );
}

class _EditMemoDialog extends StatefulWidget {
  const _EditMemoDialog({this.initialMemo});

  final String? initialMemo;

  @override
  State<_EditMemoDialog> createState() => _EditMemoDialogState();
}

class _EditMemoDialogState extends State<_EditMemoDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialMemo ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('기록 수정'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: const InputDecoration(labelText: '메모'),
      maxLines: 3,
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('저장'),
      ),
    ],
  );
}

class TripMap extends StatefulWidget {
  const TripMap({super.key, required this.trip});

  final Trip trip;

  @override
  State<TripMap> createState() => _TripMapState();
}

class _TripMapState extends State<TripMap> {
  KakaoMapController? _controller;
  StreamSubscription<CameraMoveEndEvent>? _cameraMoveSubscription;
  RouteLocation? _currentLocation;
  LatLng? _cityCenter;
  List<_ScreenRouteSegment> _screenRouteSegments = const [];
  Size _mapSize = const Size(360, 174);
  final _geocoding = Geocoding();

  List<LatLng> get _routePoints => widget.trip.routePoints
      .map(
        (point) => LatLng(latitude: point.latitude, longitude: point.longitude),
      )
      .toList();

  List<LatLng> get _photoPoints => widget.trip.photoMetadata
      .where((photo) => photo.latitude != null && photo.longitude != null)
      .map(
        (photo) =>
            LatLng(latitude: photo.latitude!, longitude: photo.longitude!),
      )
      .toList();

  DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  bool get _isPast => _today.isAfter(_dateOnly(widget.trip.endDate));
  bool get _isFuture => _today.isBefore(_dateOnly(widget.trip.startDate));

  LatLng get _center => _currentLocation == null
      ? _cityCenter ??
            (_routePoints.isNotEmpty
                ? _routePoints.first
                : _photoPoints.isNotEmpty
                ? _photoPoints.first
                : const LatLng(latitude: 37.5665, longitude: 126.9780))
      : LatLng(
          latitude: _currentLocation!.latitude,
          longitude: _currentLocation!.longitude,
        );

  @override
  void initState() {
    super.initState();
    _loadMapLocation();
  }

  @override
  void didUpdateWidget(covariant TripMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trip != widget.trip) _refreshMap();
  }

  @override
  void dispose() {
    _cameraMoveSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadMapLocation() async {
    if (_isFuture) {
      try {
        final query = widget.trip.regionType == 'domestic'
            ? '${widget.trip.regionName}, 대한민국'
            : widget.trip.regionName;
        final locations = await _geocoding.locationFromAddress(query);
        if (locations.isNotEmpty && mounted) {
          setState(
            () => _cityCenter = LatLng(
              latitude: locations.first.latitude,
              longitude: locations.first.longitude,
            ),
          );
          await _moveToPriorityView();
          return;
        }
      } catch (_) {
        // 지오코딩 실패 시 현재 위치를 대체값으로 사용합니다.
      }
    }
    try {
      final location = await LocationService().currentLocation();
      if (!mounted) return;
      setState(() => _currentLocation = location);
      if (!_isPast) await _moveToPriorityView();
    } on LocationException {
      if (mounted) await _moveToPriorityView();
    }
  }

  LatLngBounds _boundsFor(List<LatLng> points, {required bool cityScale}) {
    final latitudes = points.map((point) => point.latitude).toList();
    final longitudes = points.map((point) => point.longitude).toList();
    var south = latitudes.reduce((a, b) => a < b ? a : b);
    var north = latitudes.reduce((a, b) => a > b ? a : b);
    var west = longitudes.reduce((a, b) => a < b ? a : b);
    var east = longitudes.reduce((a, b) => a > b ? a : b);
    final minimumSpan = cityScale ? 0.05 : 0.005;
    final centerLatitude = (south + north) / 2;
    final centerLongitude = (west + east) / 2;
    if (north - south < minimumSpan) {
      south = centerLatitude - minimumSpan / 2;
      north = centerLatitude + minimumSpan / 2;
    }
    if (east - west < minimumSpan) {
      west = centerLongitude - minimumSpan / 2;
      east = centerLongitude + minimumSpan / 2;
    }
    return LatLngBounds(
      southwest: LatLng(latitude: south, longitude: west),
      northeast: LatLng(latitude: north, longitude: east),
    );
  }

  Future<void> _moveToPriorityView() async {
    final controller = _controller;
    if (controller == null) return;
    final points = <LatLng>[];
    if (_isPast || (!_isFuture && _routePoints.isNotEmpty)) {
      points.addAll(_routePoints);
      if (_isPast) points.addAll(_photoPoints);
    } else if (_isFuture && _cityCenter != null) {
      points.add(_cityCenter!);
    } else if (_currentLocation != null) {
      points.add(
        LatLng(
          latitude: _currentLocation!.latitude,
          longitude: _currentLocation!.longitude,
        ),
      );
    }
    if (points.isEmpty) points.add(_center);
    await controller.moveCamera(
      cameraUpdate: CameraUpdate.fromBounds(
        _boundsFor(points, cityScale: true),
        padding: 32,
      ),
    );
  }

  Future<void> _refreshMap() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.clearMarkers();
    await _addTripMarkers(controller);
    await _drawNativeRoutes(controller);
    await _moveToPriorityView();
    await _updateRouteOverlay();
    if (mounted) setState(() {});
  }

  Future<void> _drawNativeRoutes(KakaoMapController controller) async {
    if (Theme.of(context).platform != TargetPlatform.android) return;
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final routes = [
      for (final segment in _routeSegments)
        if (segment.points.length > 1)
          {
            'id': 'route-${segment.color.toARGB32()}',
            'color': segment.color.toARGB32().toSigned(32),
            'width': 8,
            'points': [
              for (final point in segment.points)
                {
                  'latitude': point.latitude,
                  'longitude': point.longitude,
                },
            ],
          },
    ];
    try {
      await MethodChannel(
        'view.method_channel.kakao_maps_flutter#${controller.viewId}',
      ).invokeMethod<void>('drawPolylines', {'polylines': routes});
    } on PlatformException {
      // iOS와 플러그인 구버전에서는 네이티브 경로 기능이 없습니다.
    }
  }

  Future<void> _updateRouteOverlay() async {
    if (Theme.of(context).platform == TargetPlatform.android) return;
    final controller = _controller;
    if (controller == null) return;
    final segments = <_ScreenRouteSegment>[];
    for (final segment in _routeSegments) {
      final screenPoints = <Offset>[];
      var nativeProjectionFailed = false;
      for (final point in segment.points) {
        final screenPoint = await controller.toScreenPoint(position: point);
        if (screenPoint == null ||
            screenPoint.dx.abs() > 10000 ||
            screenPoint.dy.abs() > 10000) {
          nativeProjectionFailed = true;
          break;
        }
        screenPoints.add(screenPoint);
      }
      if (nativeProjectionFailed) {
        final center = await controller.getCenter() ?? _center;
        final zoom = await controller.getZoomLevel() ?? 12;
        screenPoints
          ..clear()
          ..addAll(
            segment.points.map(
              (point) => _projectFallback(point, center, zoom),
            ),
          );
      }
      if (screenPoints.length > 1) {
        segments.add(
          _ScreenRouteSegment(points: screenPoints, color: segment.color),
        );
      }
    }
    if (mounted) setState(() => _screenRouteSegments = segments);
  }

  Offset _projectFallback(LatLng point, LatLng center, int zoom) {
    final pixelsPerDegree = 180000 / math.pow(1.4, zoom);
    final latitudeScale = pixelsPerDegree * math.cos(center.latitude * math.pi / 180);
    return Offset(
      _mapSize.width / 2 + (point.longitude - center.longitude) * pixelsPerDegree,
      _mapSize.height / 2 + (center.latitude - point.latitude) * latitudeScale,
    );
  }

  List<_RouteSegment> get _routeSegments {
    final grouped = <DateTime, List<LatLng>>{};
    final points = [...widget.trip.routePoints]
      ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
    for (final point in points) {
      final date = DateTime(
        point.recordedAt.year,
        point.recordedAt.month,
        point.recordedAt.day,
      );
      grouped.putIfAbsent(date, () => []).add(
        LatLng(latitude: point.latitude, longitude: point.longitude),
      );
    }
    final colors = [
      const Color(0xffe53935),
      const Color(0xff1e88e5),
      const Color(0xff43a047),
      const Color(0xff8e24aa),
      const Color(0xfffb8c00),
      const Color(0xff00897b),
    ];
    final entries = grouped.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return [
      for (var index = 0; index < entries.length; index++)
        _RouteSegment(
          points: entries[index].value,
          color: colors[index % colors.length],
        ),
    ];
  }

  List<_NumberedMapRecord> get _numberedMapRecords {
    final records = <_NumberedMapRecord>[];
    final points = [...widget.trip.routePoints]
      ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
    if (points.isNotEmpty) {
      records.add(
        _NumberedMapRecord(
          time: points.first.recordedAt,
          position: LatLng(
            latitude: points.first.latitude,
            longitude: points.first.longitude,
          ),
        ),
      );
      if (_isPast) {
        records.add(
          _NumberedMapRecord(
            time: points.last.recordedAt,
            position: LatLng(
              latitude: points.last.latitude,
              longitude: points.last.longitude,
            ),
          ),
        );
      }
    }
    for (final photo in widget.trip.photoMetadata) {
      if (photo.latitude == null || photo.longitude == null) continue;
      records.add(
        _NumberedMapRecord(
          time: photo.capturedAt,
          position: LatLng(
            latitude: photo.latitude!,
            longitude: photo.longitude!,
          ),
        ),
      );
    }
    records.sort((a, b) => a.time.compareTo(b.time));
    return [
      for (var index = 0; index < records.length; index++)
        records[index].copyWith(number: index + 1),
    ];
  }

  Future<void> _addTripMarkers(KakaoMapController controller) async {
    if (_isPast) {
      for (var index = 0; index < _routePoints.length; index++) {
        await controller.addMarker(
          markerOption: MarkerOption(
            id: 'route-$index',
            latLng: _routePoints[index],
          ),
        );
      }
    }
    for (final record in _numberedMapRecords) {
      await controller.addMarker(
        markerOption: MarkerOption(
          id: 'record-${record.number}',
          latLng: record.position,
          text: '(${record.number})',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 174,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                _mapSize = constraints.biggest;
                return Stack(
                  children: [
                    KakaoMap(
                      initialPosition: _center,
                      initialLevel: 12,
                      onMapCreated: (controller) async {
                        _controller = controller;
                        _cameraMoveSubscription = controller
                            .onCameraMoveEndStream
                            .listen((_) => _updateRouteOverlay());
                        await controller.addMarkerLayer(
                          layerId: KakaoMapController.defaultLabelLayerId,
                          zOrder: 1000,
                          clickable: true,
                        );
                        await _addTripMarkers(controller);
                        await _drawNativeRoutes(controller);
                        await _moveToPriorityView();
                        await _updateRouteOverlay();
                      },
                    ),
                    if (_screenRouteSegments.isNotEmpty &&
                        Theme.of(context).platform != TargetPlatform.android)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _RoutePainter(_screenRouteSegments),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            Positioned(
              top: 12,
              right: 12,
              child: Column(
                children: [
                  FloatingActionButton.small(
                    heroTag: 'map-current-location',
                    onPressed: () async {
                      try {
                        final location = await LocationService()
                            .currentLocation();
                        if (!mounted) return;
                        setState(() => _currentLocation = location);
                        final points = [
                          LatLng(
                            latitude: location.latitude,
                            longitude: location.longitude,
                          ),
                        ];
                        await _controller?.moveCamera(
                          cameraUpdate: CameraUpdate.fromBounds(
                            _boundsFor(points, cityScale: true),
                            padding: 32,
                          ),
                        );
                      } on LocationException catch (error) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(error.message)),
                          );
                        }
                      }
                    },
                    tooltip: '내 위치 중심으로 보기',
                    child: const Icon(Icons.my_location),
                  ),
                  const SizedBox(height: 8),
                  _MapZoomButton(
                    icon: Icons.add,
                    onPressed: () => _controller?.setZoomLevel(zoomLevel: 10),
                  ),
                  const SizedBox(height: 4),
                  _MapZoomButton(
                    icon: Icons.remove,
                    onPressed: () => _controller?.setZoomLevel(zoomLevel: 14),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MapZoomButton extends StatelessWidget {
  const _MapZoomButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    shape: const CircleBorder(),
    elevation: 3,
    child: IconButton(
      onPressed: onPressed,
      icon: Icon(icon),
      visualDensity: VisualDensity.compact,
      tooltip: icon == Icons.add ? '확대' : '축소',
    ),
  );
}

class _RouteSegment {
  const _RouteSegment({required this.points, required this.color});

  final List<LatLng> points;
  final Color color;
}

class _NumberedMapRecord {
  const _NumberedMapRecord({required this.time, required this.position, this.number});

  final DateTime time;
  final LatLng position;
  final int? number;

  _NumberedMapRecord copyWith({int? number}) => _NumberedMapRecord(
    time: time,
    position: position,
    number: number ?? this.number,
  );
}

class _ScreenRouteSegment {
  const _ScreenRouteSegment({required this.points, required this.color});

  final List<Offset> points;
  final Color color;
}

class _RoutePainter extends CustomPainter {
  const _RoutePainter(this.segments);

  final List<_ScreenRouteSegment> segments;

  @override
  void paint(Canvas canvas, Size size) {
    for (final segment in segments) {
      final path = Path()..moveTo(
        segment.points.first.dx,
        segment.points.first.dy,
      );
      for (final point in segment.points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = segment.color
          ..strokeWidth = 4
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RoutePainter oldDelegate) =>
      oldDelegate.segments != segments;
}

class PhotoGalleryPage extends StatefulWidget {
  const PhotoGalleryPage({super.key, required this.store, required this.trip});

  final TripStore store;
  final Trip trip;

  @override
  State<PhotoGalleryPage> createState() => _PhotoGalleryPageState();
}

class _PhotoGalleryPageState extends State<PhotoGalleryPage> {
  late Trip _trip;
  List<AssetEntity> _assets = const [];
  Set<String> _selected = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _trip = widget.trip;
    _loadPhotos();
  }

  DateTime _day(DateTime value) => DateTime(value.year, value.month, value.day);

  Future<void> _loadPhotos() async {
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.hasAccess) throw Exception('사진 접근 권한을 허용해주세요.');
      final paths = await PhotoManager.getAssetPathList(
        onlyAll: true,
        type: RequestType.image,
      );
      if (paths.isEmpty) throw Exception('사진첩을 찾을 수 없습니다.');
      final album = paths.first;
      final count = await album.assetCountAsync;
      final assets = count == 0
          ? <AssetEntity>[]
          : await album.getAssetListRange(
              start: 0,
              end: count,
              type: RequestType.image,
            );
      final start = _day(_trip.startDate);
      final end = _day(_trip.endDate);
      final hidden = _trip.hiddenPhotoIds.toSet();
      final visible = assets.where((asset) {
        final created = _day(asset.createDateTime);
        return !hidden.contains(asset.id) &&
            !created.isBefore(start) &&
            !created.isAfter(end);
      }).toList();
      if (!mounted) return;
      setState(() {
        _assets = visible;
        _selected = _trip.photoMetadata.map((photo) => photo.assetId).toSet();
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
      }
    }
  }

  Future<void> _saveSelected() async {
    final metadata = [
      ..._trip.photoMetadata.where(
        (photo) => _selected.contains(photo.assetId),
      ),
    ];
    for (final asset in _assets.where(
      (asset) => _selected.contains(asset.id),
    )) {
      if (metadata.any((photo) => photo.assetId == asset.id)) continue;
      final file = await asset.file;
      final position = asset.latLng ?? await asset.latlngAsync();
      metadata.add(
        PhotoMetadata(
          assetId: asset.id,
          capturedAt: asset.createDateTime,
          filePath:
              file?.path ??
              '${asset.relativePath ?? ''}${asset.title ?? asset.id}',
          latitude: position?.latitude,
          longitude: position?.longitude,
        ),
      );
    }
    _trip = _trip.copyWith(photoMetadata: metadata);
    await widget.store.save(_trip);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('사진 메타데이터를 저장했습니다.')));
  }

  Future<void> _hideSelected() async {
    if (_selected.isEmpty) return;
    final hidden = {..._trip.hiddenPhotoIds, ..._selected};
    _trip = _trip.copyWith(
      hiddenPhotoIds: hidden.toList(),
      photoMetadata: _trip.photoMetadata
          .where((photo) => !hidden.contains(photo.assetId))
          .toList(),
    );
    await widget.store.save(_trip);
    if (!mounted) return;
    setState(() {
      _assets = _assets.where((asset) => !hidden.contains(asset.id)).toList();
      _selected = {};
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('여행 사진'),
        actions: [
          IconButton(
            onPressed: _selected.isEmpty ? null : _saveSelected,
            icon: const Icon(Icons.save_outlined),
            tooltip: '메타데이터 저장',
          ),
          IconButton(
            onPressed: _selected.isEmpty ? null : _hideSelected,
            icon: const Icon(Icons.delete_outline),
            tooltip: '메타데이터 삭제',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : _assets.isEmpty
          ? const Center(child: Text('여행기간에 촬영한 사진이 없습니다.'))
          : GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
              ),
              itemCount: _assets.length,
              itemBuilder: (context, index) {
                final asset = _assets[index];
                final selected = _selected.contains(asset.id);
                return GestureDetector(
                  onTap: () => setState(() {
                    if (selected) {
                      _selected.remove(asset.id);
                    } else {
                      _selected.add(asset.id);
                    }
                  }),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      FutureBuilder<Uint8List?>(
                        future: asset.thumbnailDataWithSize(
                          const ThumbnailSize.square(240),
                        ),
                        builder: (context, snapshot) => snapshot.hasData
                            ? Image.memory(snapshot.data!, fit: BoxFit.cover)
                            : const ColoredBox(color: Colors.black12),
                      ),
                      if (selected)
                        const Align(
                          alignment: Alignment.topRight,
                          child: Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.check_circle,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _locationKey = 'location_collection_enabled';
  static const _backgroundKey = 'background_location_enabled';
  final _preferences = SharedPreferencesAsync();
  final _locationService = LocationService();
  bool _locationEnabled = true;
  bool _backgroundEnabled = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final location = await _preferences.getBool(_locationKey);
    final background = await _preferences.getBool(_backgroundKey);
    if (!mounted) return;
    setState(() {
      _locationEnabled = location ?? true;
      _backgroundEnabled = background ?? false;
      _loading = false;
    });
  }

  Future<void> _setLocation(bool enabled) async {
    if (enabled) {
      try {
        await _locationService.ensurePermission();
      } on LocationException catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(error.message)));
        }
        return;
      }
    }
    await _preferences.setBool(_locationKey, enabled);
    if (mounted) setState(() => _locationEnabled = enabled);
  }

  Future<void> _setBackground(bool enabled) async {
    if (enabled) {
      try {
        await _locationService.ensureBackgroundPermission();
      } on LocationException catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(error.message)));
        }
        return;
      }
    }
    await _preferences.setBool(_backgroundKey, enabled);
    if (mounted) setState(() => _backgroundEnabled = enabled);
  }

  @override
  void dispose() {
    _locationService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('앱 전체 설정')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile(
                  value: _locationEnabled,
                  onChanged: _setLocation,
                  secondary: const Icon(Icons.location_on_outlined),
                  title: const Text('위치 수집'),
                  subtitle: const Text('여행기간 중 5분 간격으로 위치를 저장합니다.'),
                ),
                SwitchListTile(
                  value: _backgroundEnabled,
                  onChanged: _locationEnabled ? _setBackground : null,
                  secondary: const Icon(Icons.battery_saver_outlined),
                  title: const Text('백그라운드 위치 수집'),
                  subtitle: const Text('앱이 백그라운드일 때도 위치를 수집하고 알림을 표시합니다.'),
                ),
              ],
            ),
    );
  }
}

String _date(DateTime date) =>
    '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';

String _tripLocation(Trip trip) =>
    '${trip.regionName}/${trip.countryName ?? (trip.regionType == 'domestic' ? '대한민국' : '국가')}';

DateTime _dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);

bool _isTripActive(Trip trip) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final start = DateTime(
    trip.startDate.year,
    trip.startDate.month,
    trip.startDate.day,
  );
  final end = DateTime(trip.endDate.year, trip.endDate.month, trip.endDate.day);
  return !today.isBefore(start) && !today.isAfter(end);
}

String _dateTime(DateTime date) =>
    '${_date(date)} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

String _shortDateTime(DateTime date) =>
    '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
