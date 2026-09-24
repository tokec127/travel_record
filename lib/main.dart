import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

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
          '여행 기간 동안 10분 간격으로 위치를 자동 저장합니다. '
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
    final intervalMinutes =
        await preferences.getInt('location_interval_minutes') ??
        LocationService.defaultCollectionInterval.inMinutes;
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
        interval: Duration(minutes: intervalMinutes.clamp(1, 1440)),
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

class _TripDetailPageState extends State<TripDetailPage>
    with WidgetsBindingObserver {
  static const _recordAccent = Color(0xff64b5f6);
  static const _fileChannel = MethodChannel('travel_record/files');
  final _locationService = LocationService();
  final _weatherService = WeatherService();
  late Trip _trip;
  bool _loading = false;
  String _weatherStatus = '날씨 정보를 불러오는 중...';
  bool _selectionMode = false;
  bool _recordDialogOpen = false;
  bool _photoSyncing = false;
  final Set<String> _selectedRecordIds = {};
  final Set<DateTime> _collapsedDates = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _trip = widget.trip;
    _collapsedDates.addAll(_recordDates(_trip));
    _loadLatestTrip().then((_) async {
      await _syncPhotos();
      await _loadWeather();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) _syncPhotos();
  }

  Future<void> _syncPhotos() async {
    if (_photoSyncing) return;
    _photoSyncing = true;
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.hasAccess) return;
      final paths = await PhotoManager.getAssetPathList(
        onlyAll: true,
        type: RequestType.image,
      );
      if (paths.isEmpty) return;
      final album = paths.first;
      final count = await album.assetCountAsync;
      if (count == 0) return;
      final assets = await album.getAssetListRange(
        start: 0,
        end: count,
        type: RequestType.image,
      );
      final start = _dateOnly(_trip.startDate);
      final end = _dateOnly(_trip.endDate);
      final hidden = _trip.hiddenPhotoIds.toSet();
      final known = _trip.photoMetadata.map((photo) => photo.assetId).toSet();
      final photos = [..._trip.photoMetadata];
      for (final asset in assets) {
        final created = _dateOnly(asset.createDateTime);
        if (known.contains(asset.id) ||
            hidden.contains(asset.id) ||
            created.isBefore(start) ||
            created.isAfter(end)) {
          continue;
        }
        photos.add(await _photoMetadataFromAsset(asset, _trip.routePoints));
        known.add(asset.id);
      }
      if (photos.length == _trip.photoMetadata.length) return;
      final updated = _trip.copyWith(photoMetadata: photos);
      await widget.store.save(updated);
      if (mounted) setState(() => _trip = updated);
    } catch (_) {
      // 사진 접근이 불가능해도 여행 기록 화면은 계속 표시한다.
    } finally {
      _photoSyncing = false;
    }
  }

  Future<void> _pickPreparationFile(String key) async {
    final selected = _trip.preparationFiles[key];
    if (selected != null) {
      await _fileChannel.invokeMethod<void>('openFile', {'uri': selected.uri});
      return;
    }
    final result = await _fileChannel.invokeMethod<Map<Object?, Object?>>(
      'pickFile',
    );
    if (!mounted || result == null) return;
    final name = result['name'] as String?;
    final uri = result['uri'] as String?;
    if (name == null || uri == null) return;
    _trip = _trip.copyWith(
      preparationFiles: {
        ..._trip.preparationFiles,
        key: PreparationFile(name: name, uri: uri),
      },
    );
    await widget.store.save(_trip);
    if (mounted) setState(() {});
  }

  Future<void> _loadLatestTrip() async {
    final trips = await widget.store.readAll();
    final latest = trips.where((trip) => trip.id == widget.trip.id).firstOrNull;
    if (latest == null) return;
    final photos = [...latest.photoMetadata];
    var changed = false;
    for (var index = 0; index < photos.length; index++) {
      final photo = photos[index];
      if (photo.latitude != null || photo.longitude != null) continue;
      final position = _nearestRoutePosition(
        latest.routePoints,
        photo.capturedAt,
      );
      if (position == null) continue;
      photos[index] = PhotoMetadata(
        assetId: photo.assetId,
        capturedAt: photo.capturedAt,
        filePath: photo.filePath,
        title: photo.title,
        memo: photo.memo,
        place: photo.place,
        mediaType: photo.mediaType,
        latitude: position.latitude,
        longitude: position.longitude,
      );
      changed = true;
    }
    final updated = changed ? latest.copyWith(photoMetadata: photos) : latest;
    if (changed) await widget.store.save(updated);
    if (mounted) {
      setState(() {
        _trip = updated;
        _collapsedDates.addAll(_recordDates(updated));
      });
    }
  }

  Set<DateTime> _recordDates(Trip trip) => {
    ...trip.routePoints.map((point) => _dateOnly(point.recordedAt)),
    ...trip.photoMetadata.map((photo) => _dateOnly(photo.capturedAt)),
    ...trip.manualRecords.map((record) => _dateOnly(record.recordedAt)),
  };

  Future<void> _loadWeather() async {
    final targetDate = _weatherTargetDate;
    final dates = <DateTime>{
      targetDate,
      ..._trip.routePoints.map((point) => _dateOnly(point.recordedAt)),
      ..._trip.photoMetadata.map((photo) => _dateOnly(photo.capturedAt)),
    }.toList()..sort();
    var records = [..._trip.weatherRecords];
    var changed = false;
    String? targetStatus;
    for (final date in dates) {
      final existing = records
          .where((record) => _dateOnly(record.date) == date)
          .firstOrNull;
      final isPast = date.isBefore(_dateOnly(DateTime.now()));
      final isToday = _dateOnly(date) == _dateOnly(DateTime.now());
      if (existing != null &&
          !isToday &&
          (!isPast || existing.source == '과거 날씨')) {
        continue;
      }
      try {
        final record = await _weatherService.fetchRecord(_trip, date: date);
        if (record == null) {
          if (date == targetDate) targetStatus = '해당 여행일의 날씨 정보가 없습니다.';
          continue;
        }
        records.removeWhere((item) => _dateOnly(item.date) == date);
        records.add(record);
        changed = true;
        if (date == targetDate) targetStatus = record.summary;
      } on WeatherException catch (error) {
        if (date == targetDate) targetStatus = error.message;
      } catch (_) {
        if (date == targetDate) targetStatus = '날씨 서버에 연결하지 못했습니다.';
      }
    }
    final targetRecord = records
        .where((record) => _dateOnly(record.date) == targetDate)
        .firstOrNull;
    if (targetRecord != null) targetStatus = targetRecord.summary;
    if (changed) {
      final updated = _trip.copyWith(
        weatherSummary: targetRecord?.summary ?? _trip.weatherSummary,
        weatherDate: targetRecord == null ? _trip.weatherDate : targetDate,
        weatherRecords: records,
      );
      await widget.store.save(updated);
      if (mounted) setState(() => _trip = updated);
    }
    if (targetStatus != null && mounted) {
      setState(() => _weatherStatus = targetStatus!);
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

  bool get _isPastTrip =>
      _dateOnly(DateTime.now()).isAfter(_dateOnly(_trip.endDate));

  bool get _isFutureTrip =>
      _dateOnly(DateTime.now()).isBefore(_dateOnly(_trip.startDate));

  bool _isInfoEntry(String title) =>
      title == '날씨' || title == '여행요약' || title == '여행준비';

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
    return _weatherIconFor(_weatherTargetDate);
  }

  IconData _weatherIconFor(DateTime date) {
    final record = _weatherRecordFor(date);
    final text = (record?.weatherAt(date) ?? _weatherText).toLowerCase();
    if (text.contains('비') || text.contains('rain')) return Icons.umbrella;
    if (text.contains('눈') || text.contains('snow')) return Icons.ac_unit;
    if (text.contains('흐림') ||
        text.contains('구름') ||
        text.contains('cloud') ||
        text.contains('overcast')) {
      return Icons.cloud_outlined;
    }
    return date.hour >= 18
        ? Icons.nights_stay_outlined
        : Icons.wb_sunny_outlined;
  }

  String? _temperatureMemo(DateTime date) {
    final record = _weatherRecordFor(date);
    final maximum = record?.maximumTemperature;
    final minimum = record?.minimumTemperature;
    if (maximum == null || minimum == null) return null;
    return '최고 ${maximum.toStringAsFixed(0)}°C / 최저 ${minimum.toStringAsFixed(0)}°C';
  }

  WeatherRecord? _weatherRecordFor(DateTime date) {
    for (final record in _trip.weatherRecords) {
      if (_dateOnly(record.date) == _dateOnly(date)) return record;
    }
    return null;
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

  void _toggleDay(DateTime date) => setState(() {
    final day = _dateOnly(date);
    if (!_collapsedDates.add(day)) _collapsedDates.remove(day);
  });

  _TimelineEntry? get _selectedStartEntry => _timelineEntries()
      .where(
        (entry) =>
            entry.badge == 'S' &&
            entry.id != null &&
            _selectedRecordIds.contains(entry.id),
      )
      .firstOrNull;

  Future<void> _deleteSelectedRecords() async {
    if (_selectedRecordIds.isEmpty) return;
    final deletableEntries = _timelineEntries().where(
      (entry) =>
          _selectedRecordIds.contains(entry.id) &&
          (entry.photo != null || entry.manualRecord != null),
    );
    if (deletableEntries.isEmpty) return;
    final selectedPhotoIds = <String>{};
    final selectedManualIds = <String>{};
    for (final entry in _timelineEntries()) {
      if (entry.id != null && _selectedRecordIds.contains(entry.id)) {
        selectedPhotoIds.addAll(
          entry.groupPhotos.map((photo) => photo.assetId),
        );
        if (entry.manualRecord != null) {
          selectedManualIds.add(entry.manualRecord!.id);
        }
      }
    }
    final hidden = {..._trip.hiddenPhotoIds, ...selectedPhotoIds};
    _trip = _trip.copyWith(
      hiddenPhotoIds: hidden.toList(),
      photoMetadata: _trip.photoMetadata
          .where((photo) => !hidden.contains(photo.assetId))
          .toList(),
      manualRecords: _trip.manualRecords
          .where((record) => !selectedManualIds.contains(record.id))
          .toList(),
    );
    await widget.store.save(_trip);
    if (!mounted) return;
    setState(() {
      _selectedRecordIds.clear();
      _selectionMode = false;
    });
  }

  Future<void> _editSelectedStart() async {
    final entry = _selectedStartEntry;
    if (entry != null) await _showRecordActions(entry);
  }

  Future<void> _addManualRecord() async {
    final draft = await showDialog<_ManualRecordDraft>(
      context: context,
      builder: (_) => const _AddRecordDialog(),
    );
    if (draft == null) return;
    if (!mounted) return;
    if (draft.kind == 'photo') {
      final assets = await showDialog<List<AssetEntity>>(
        context: context,
        builder: (_) => _PhotoPickerDialog(
          startDate: _trip.startDate,
          endDate: _trip.endDate,
        ),
      );
      if (assets == null || assets.isEmpty) return;
      final photos = [..._trip.photoMetadata];
      final known = photos.map((photo) => photo.assetId).toSet();
      for (final asset in assets) {
        if (!known.add(asset.id)) continue;
        final photo = await _photoMetadataFromAsset(asset, _trip.routePoints);
        photos.add(
          PhotoMetadata(
            assetId: photo.assetId,
            capturedAt: photo.capturedAt,
            filePath: photo.filePath,
            title: draft.title.trim().isEmpty ? null : draft.title.trim(),
            memo: draft.memo.trim().isEmpty ? null : draft.memo.trim(),
            place: draft.place.trim().isEmpty ? null : draft.place.trim(),
            mediaType: photo.mediaType,
            latitude: photo.latitude,
            longitude: photo.longitude,
          ),
        );
      }
      _trip = _trip.copyWith(photoMetadata: photos);
      await widget.store.save(_trip);
      if (mounted) setState(() {});
      return;
    }
    final record = ManualRecord(
      id: draft.recordedAt.microsecondsSinceEpoch.toString(),
      recordedAt: draft.recordedAt,
      kind: draft.kind,
      title: draft.title.trim(),
      memo: draft.memo.trim(),
      place: draft.place.trim(),
    );
    _trip = _trip.copyWith(manualRecords: [..._trip.manualRecords, record]);
    await widget.store.save(_trip);
    if (mounted) setState(() {});
  }

  Future<void> _showRecordActions(_TimelineEntry entry) async {
    if (_recordDialogOpen) return;
    _recordDialogOpen = true;
    try {
      final result = await showDialog<_RecordDialogResult>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        barrierColor: Colors.black54,
        builder: (_) => _RecordDetailDialog(entry: entry),
      );
      if (!mounted || result == null) return;
      if (result.action == _RecordDialogAction.save && entry.photo != null) {
        await _savePhotoMemo(
          entry.photo!,
          result.memo ?? '',
          result.place ?? '',
          result.title ?? '',
        );
      } else if (result.action == _RecordDialogAction.save &&
          entry.routePoint != null) {
        await _saveRouteMemo(entry.routePoint!, result.memo ?? '');
      } else if (result.action == _RecordDialogAction.save &&
          entry.manualRecord != null) {
        await _saveManualRecord(
          entry.manualRecord!,
          result.title ?? '',
          result.place ?? '',
          result.memo ?? '',
        );
      } else if (result.action == _RecordDialogAction.delete) {
        if (result.photoIds?.isNotEmpty == true) {
          await _deleteSelectedPhotos(result.photoIds!);
        } else {
          await _deleteRecord(entry);
        }
      }
    } finally {
      _recordDialogOpen = false;
    }
  }

  Future<void> _saveRouteMemo(RoutePoint point, String memo) async {
    final updated = _trip.routePoints.map((item) {
      if (item.recordedAt != point.recordedAt) return item;
      return RoutePoint(
        recordedAt: item.recordedAt,
        latitude: item.latitude,
        longitude: item.longitude,
        accuracy: item.accuracy,
        memo: memo.trim().isEmpty ? null : memo.trim(),
      );
    }).toList();
    _trip = _trip.copyWith(routePoints: updated);
    await widget.store.save(_trip);
    if (mounted) setState(() {});
  }

  Future<void> _saveManualRecord(
    ManualRecord record,
    String title,
    String place,
    String memo,
  ) async {
    final updated = _trip.manualRecords.map((item) {
      if (item.id != record.id) return item;
      return ManualRecord(
        id: item.id,
        recordedAt: item.recordedAt,
        kind: item.kind,
        title: title.trim(),
        memo: memo.trim(),
        place: place.trim().isEmpty ? null : place.trim(),
      );
    }).toList();
    _trip = _trip.copyWith(manualRecords: updated);
    await widget.store.save(_trip);
    if (mounted) setState(() {});
  }

  Future<void> _savePhotoMemo(
    PhotoMetadata photo,
    String memo,
    String place,
    String title,
  ) async {
    final index = _trip.photoMetadata.indexWhere(
      (item) => item.assetId == photo.assetId,
    );
    if (index < 0) return;
    final updated = [..._trip.photoMetadata];
    updated[index] = PhotoMetadata(
      assetId: photo.assetId,
      capturedAt: photo.capturedAt,
      filePath: photo.filePath,
      title: title.trim().isEmpty ? null : title.trim(),
      memo: memo.trim().isEmpty ? null : memo.trim(),
      place: place.trim().isEmpty ? null : place.trim(),
      mediaType: photo.mediaType,
      latitude: photo.latitude,
      longitude: photo.longitude,
    );
    _trip = _trip.copyWith(photoMetadata: updated);
    await widget.store.save(_trip);
    if (mounted) setState(() {});
  }

  Future<void> _deleteRecord(_TimelineEntry entry) async {
    if (entry.photo != null) {
      final ids = entry.groupPhotos.map((photo) => photo.assetId).toSet();
      _trip = _trip.copyWith(
        hiddenPhotoIds: {..._trip.hiddenPhotoIds, ...ids}.toList(),
        photoMetadata: _trip.photoMetadata
            .where((photo) => !ids.contains(photo.assetId))
            .toList(),
      );
      await widget.store.save(_trip);
      if (mounted) setState(() {});
      return;
    }
    if (entry.manualRecord != null) {
      _trip = _trip.copyWith(
        manualRecords: _trip.manualRecords
            .where((record) => record.id != entry.manualRecord!.id)
            .toList(),
      );
      await widget.store.save(_trip);
      if (mounted) setState(() {});
      return;
    }
    final points = [..._trip.routePoints]
      ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
    if (points.isEmpty) return;
    final routePoint = entry.routePoint;
    if (routePoint == null) {
      return;
    }
    points.removeWhere((point) => point.recordedAt == routePoint.recordedAt);
    _trip = _trip.copyWith(routePoints: points);
    await widget.store.save(_trip);
    if (mounted) setState(() {});
  }

  Future<void> _deleteSelectedPhotos(Set<String> photoIds) async {
    _trip = _trip.copyWith(
      hiddenPhotoIds: {..._trip.hiddenPhotoIds, ...photoIds}.toList(),
      photoMetadata: _trip.photoMetadata
          .where((photo) => !photoIds.contains(photo.assetId))
          .toList(),
    );
    await widget.store.save(_trip);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_trip.regionName),
        actions: [
          if (_selectionMode) ...[
            if (_selectedStartEntry != null)
              IconButton(
                onPressed: _editSelectedStart,
                icon: const Icon(Icons.edit_outlined),
                tooltip: '시작 카드 수정',
              ),
            IconButton(
              onPressed: _deleteSelectedRecords,
              icon: const Icon(Icons.delete_outline),
              tooltip: '선택 항목 삭제',
            ),
            IconButton(
              onPressed: _addManualRecord,
              icon: const Icon(Icons.add),
              tooltip: '여행 기록 추가',
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
            child: TripMap(
              trip: _trip,
              collapsedDates: Set.unmodifiable(_collapsedDates),
              onRecordTap: _showRecordByNumber,
            ),
          ),
          const SizedBox(height: 8),
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

  List<_TimelineEntry> _timelineEntries() {
    final entries = <_TimelineEntry>[];
    final points = [..._trip.routePoints]
      ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
    final pointsByDate = <DateTime, List<RoutePoint>>{};
    for (final point in points) {
      pointsByDate
          .putIfAbsent(_dateOnly(point.recordedAt), () => [])
          .add(point);
    }
    for (final day in pointsByDate.keys.toList()..sort()) {
      final dayPoints = pointsByDate[day]!;
      final first = _startPoint(dayPoints);
      entries.add(
        _TimelineEntry(
          time: first.recordedAt,
          title:
              '시작(${first.recordedAt.year}/${first.recordedAt.month.toString().padLeft(2, '0')}/${first.recordedAt.day.toString().padLeft(2, '0')})',
          detail: _coordinate(first.latitude, first.longitude),
          memo: first.memo?.trim().isNotEmpty == true
              ? first.memo
              : _temperatureMemo(first.recordedAt),
          icon: _weatherIconFor(first.recordedAt),
          id: 'start-${first.recordedAt.microsecondsSinceEpoch}',
          badge: 'S',
          routePoint: first,
        ),
      );
    }
    for (final group in _photoGroups()) {
      final photo = group.photo;
      final place = photo.latitude == null
          ? '장소 정보 없음'
          : _coordinate(photo.latitude!, photo.longitude!);
      final memo = photo.memo?.trim();
      final hasMemo = memo != null && memo.isNotEmpty;
      entries.add(
        _TimelineEntry(
          time: photo.capturedAt,
          title: photo.title?.trim().isNotEmpty == true
              ? photo.title!.trim()
              : _isVideo(photo)
              ? '동영상'
              : '사진',
          detail: hasMemo
              ? memo
              : '${_dateTime(photo.capturedAt)} · $place\n${photo.filePath}',
          memo: memo,
          icon: hasMemo ? Icons.note_alt_outlined : Icons.photo_outlined,
          id: photo.assetId,
          photo: photo,
          groupPhotos: group.photos,
          groupCount: group.count,
        ),
      );
    }
    for (final record in _trip.manualRecords) {
      entries.add(
        _TimelineEntry(
          time: record.recordedAt,
          title: record.title.isEmpty
              ? (record.kind == 'payment' ? '결제' : '메모')
              : record.title,
          detail: record.memo,
          memo: record.memo,
          icon: record.kind == 'payment'
              ? Icons.receipt_long_outlined
              : Icons.note_alt_outlined,
          id: record.id,
          manualRecord: record,
        ),
      );
    }
    final infoTitle = _isPastTrip
        ? '여행요약'
        : _isFutureTrip
        ? '여행준비'
        : '날씨';
    entries.add(
      _TimelineEntry(
        time: _dateOnly(DateTime.now()),
        title: infoTitle,
        detail: '',
        icon: Icons.cloud_outlined,
      ),
    );
    entries.sort((a, b) {
      if (_isInfoEntry(a.title)) return -1;
      if (_isInfoEntry(b.title)) return 1;
      return a.time.compareTo(b.time);
    });
    var sequence = 0;
    for (var index = 0; index < entries.length; index++) {
      if (!_isInfoEntry(entries[index].title) && entries[index].badge == null) {
        sequence++;
        entries[index] = entries[index].copyWith(sequence: sequence);
      }
    }
    return entries;
  }

  RoutePoint _startPoint(List<RoutePoint> points) {
    final first = points.first;
    return points
        .skip(1)
        .firstWhere(
          (point) => _routeDistanceMeters(first, point) >= 10,
          orElse: () => first,
        );
  }

  double _routeDistanceMeters(RoutePoint a, RoutePoint b) {
    const radius = 6371000.0;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final h =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return radius * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  }

  List<_PhotoGroup> _photoGroups() {
    final photos = [..._trip.photoMetadata]
      ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
    final groups = <_PhotoGroup>[];
    PhotoMetadata? previous;
    for (final photo in photos) {
      final grouped =
          previous != null &&
          photo.capturedAt.difference(previous.capturedAt).abs() <=
              const Duration(minutes: 30) &&
          _distanceMeters(photo, previous) <= 100;
      if (!grouped) {
        groups.add(_PhotoGroup(photo: photo, photos: [photo]));
      } else {
        final group = groups.last;
        groups[groups.length - 1] = _PhotoGroup(
          photo: group.photo,
          photos: [...group.photos, photo],
        );
      }
      previous = photo;
    }
    return groups;
  }

  double _distanceMeters(PhotoMetadata a, PhotoMetadata b) {
    if (a.latitude == null ||
        a.longitude == null ||
        b.latitude == null ||
        b.longitude == null) {
      return double.infinity;
    }
    const radius = 6371000.0;
    final lat1 = a.latitude! * math.pi / 180;
    final lat2 = b.latitude! * math.pi / 180;
    final dLat = (b.latitude! - a.latitude!) * math.pi / 180;
    final dLon = (b.longitude! - a.longitude!) * math.pi / 180;
    final h =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return radius * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  }

  Future<void> _showRecordByNumber(int number) async {
    final records = _timelineEntries()
        .where((entry) => !_isInfoEntry(entry.title) && entry.badge == null)
        .toList();
    if (number < 1 || number > records.length) return;
    await _showRecordActions(records[number - 1]);
  }

  Widget _buildRecordList() {
    final entries = _timelineEntries()
        .where(
          (entry) =>
              _isInfoEntry(entry.title) ||
              entry.badge == 'S' ||
              !_collapsedDates.contains(_dateOnly(entry.time)),
        )
        .toList();
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
        if (_isInfoEntry(entry.title)) return _buildInfoRecordCard(entry.title);
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _recordAccent.withAlpha(55)),
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _selectionMode
                ? (entry.id == null ? null : () => _toggleRecord(entry.id!))
                : entry.badge == 'S'
                ? () => _toggleDay(entry.time)
                : () => _showRecordActions(entry),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                height: 52,
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 26,
                      child: Container(height: 1, color: Colors.black12),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 32,
                          height: 52,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Positioned.fill(
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Center(
                                    child: Container(
                                      width: 2,
                                      color: _recordAccent.withAlpha(80),
                                    ),
                                  ),
                                ),
                              ),
                              Container(
                                width: 28,
                                height: 28,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: _dateColor(
                                    _trip.startDate,
                                    entry.time,
                                  ),
                                  shape: BoxShape.circle,
                                ),
                                child: Text(
                                  entry.badge ?? '${entry.sequence ?? ''}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 42,
                          height: 52,
                          child: Center(
                            child: SizedBox(
                              width: 42,
                              height: 42,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: _thumbnail(entry),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                height: 26,
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text.rich(
                                        TextSpan(
                                          text: entry.title,
                                          children: [
                                            if ((entry.photo?.place ??
                                                        entry
                                                            .manualRecord
                                                            ?.place)
                                                    ?.trim()
                                                    .isNotEmpty ==
                                                true)
                                              TextSpan(
                                                text:
                                                    ' @${(entry.photo?.place ?? entry.manualRecord?.place)!.trim()}',
                                                style: TextStyle(
                                                  color: _dateColor(
                                                    _trip.startDate,
                                                    entry.time,
                                                  ),
                                                ),
                                              ),
                                          ],
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14,
                                          ),
                                        ),
                                        maxLines: 1,
                                        softWrap: false,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      _shortDateTime(entry.time),
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(color: Colors.black45),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(
                                height: 26,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    entry.memo ?? '',
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      color: Colors.black45,
                                    ),
                                  ),
                                ),
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
                  ],
                ),
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

  Widget _buildInfoRecordCard(String title) {
    if (title == '날씨') {
      return SizedBox(
        height: 76,
        child: PageView(
          children: [_buildWeatherRecordCard(), _buildPreparationCard()],
        ),
      );
    }
    final isSummary = title == '여행요약';
    final country =
        _trip.countryName ?? (_trip.regionType == 'domestic' ? '대한민국' : '국가');
    if (!isSummary) return _buildPreparationCard();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              '여행기간 ${_date(_trip.startDate)} ~ ${_date(_trip.endDate)}  ·  도시 ${_trip.regionName}  ·  나라 $country',
              style: const TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreparationCard() => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '여행준비',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 0),
          Expanded(
            child: Row(
              children: [
                for (final item in const [
                  ('passport', '여권'),
                  ('lodging', '숙소'),
                  ('flight', '항공권'),
                ])
                  Expanded(
                    child: InkWell(
                      onTap: () => _pickPreparationFile(item.$1),
                      child: Row(
                        children: [
                          Icon(
                            _trip.preparationFiles.containsKey(item.$1)
                                ? Icons.attach_file
                                : Icons.add,
                            size: 16,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              item.$2,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _thumbnail(_TimelineEntry entry) {
    final photo = entry.photo;
    if (photo == null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xffe7f1fb),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(child: Icon(entry.icon, color: Colors.black)),
          ),
        ],
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<AssetEntity?>(
            future: AssetEntity.fromId(photo.assetId),
            builder: (context, assetSnapshot) {
              final asset = assetSnapshot.data;
              if (asset == null) {
                return const ColoredBox(color: Colors.black12);
              }
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
          if (_isVideo(photo))
            const Align(
              alignment: Alignment.center,
              child: Icon(
                Icons.play_circle_fill,
                color: Colors.white,
                size: 24,
              ),
            ),
          if (entry.groupCount > 1) _photoCountBadge(entry.groupCount),
        ],
      ),
    );
  }

  Widget _photoCountBadge(int count) => Positioned(
    right: 3,
    bottom: 3,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      color: Colors.black87,
      child: Text(
        '$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );

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
    this.badge,
    this.routePoint,
    this.memo,
    this.groupCount = 1,
    this.groupPhotos = const [],
    this.manualRecord,
  });

  final DateTime time;
  final String title;
  final String detail;
  final IconData icon;
  final String? id;
  final PhotoMetadata? photo;
  final int? sequence;
  final String? badge;
  final RoutePoint? routePoint;
  final String? memo;
  final int groupCount;
  final List<PhotoMetadata> groupPhotos;
  final ManualRecord? manualRecord;

  _TimelineEntry copyWith({int? sequence}) => _TimelineEntry(
    time: time,
    title: title,
    detail: detail,
    icon: icon,
    id: id,
    photo: photo,
    sequence: sequence ?? this.sequence,
    badge: badge,
    routePoint: routePoint,
    memo: memo,
    groupCount: groupCount,
    groupPhotos: groupPhotos,
    manualRecord: manualRecord,
  );
}

class _PhotoGroup {
  const _PhotoGroup({required this.photo, required this.photos});

  final PhotoMetadata photo;
  final List<PhotoMetadata> photos;

  int get count => photos.length;
}

enum _RecordDialogAction { save, delete }

class _RecordDialogResult {
  const _RecordDialogResult(
    this.action, {
    this.title,
    this.memo,
    this.place,
    this.photoIds,
  });

  final _RecordDialogAction action;
  final String? title;
  final String? memo;
  final String? place;
  final Set<String>? photoIds;
}

class _RecordDetailDialog extends StatefulWidget {
  const _RecordDetailDialog({required this.entry});

  final _TimelineEntry entry;

  @override
  State<_RecordDetailDialog> createState() => _RecordDetailDialogState();
}

class _RecordDetailDialogState extends State<_RecordDetailDialog> {
  late final TextEditingController _title = TextEditingController(
    text: widget.entry.photo?.title ?? widget.entry.title,
  );
  late final TextEditingController _memo = TextEditingController(
    text:
        widget.entry.photo?.memo ??
        widget.entry.routePoint?.memo ??
        widget.entry.manualRecord?.memo ??
        '',
  );
  late final TextEditingController _placeController = TextEditingController(
    text: widget.entry.photo?.place ?? widget.entry.manualRecord?.place ?? '',
  );
  late final Map<String, Future<Uint8List?>> _photoBytes = {
    for (final photo in widget.entry.groupPhotos)
      photo.assetId: _loadPhotoBytes(photo.assetId),
  };
  final Set<String> _selectedPhotoIds = {};

  Future<Uint8List?> _loadPhotoBytes(String assetId) async {
    final asset = await AssetEntity.fromId(assetId);
    return asset?.thumbnailDataWithSize(const ThumbnailSize(800, 800));
  }

  Future<void> _openPhotoViewer(
    PhotoMetadata photo, {
    List<PhotoMetadata>? groupPhotos,
  }) async {
    final photos = groupPhotos ?? [photo];
    final index = photos.indexWhere((item) => item.assetId == photo.assetId);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => _PhotoGroupViewer(
        photos: photos,
        initialIndex: index < 0 ? 0 : index,
      ),
    );
  }

  void _togglePhotoSelection(String assetId) => setState(() {
    if (!_selectedPhotoIds.add(assetId)) _selectedPhotoIds.remove(assetId);
  });

  @override
  void dispose() {
    _title.dispose();
    _memo.dispose();
    _placeController.dispose();
    super.dispose();
  }

  String get _place {
    final photo = widget.entry.photo;
    if (photo == null || photo.latitude == null || photo.longitude == null) {
      return widget.entry.detail;
    }
    return '${photo.latitude!.toStringAsFixed(4)}, ${photo.longitude!.toStringAsFixed(4)}';
  }

  Widget _photoPreview() {
    final photo = widget.entry.photo;
    if (photo == null) return const SizedBox.shrink();
    if (widget.entry.groupPhotos.length > 1) {
      return SizedBox(
        height: 256,
        child: GridView.builder(
          padding: EdgeInsets.zero,
          primary: false,
          physics: const AlwaysScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 4,
            mainAxisSpacing: 4,
          ),
          itemCount: widget.entry.groupPhotos.length,
          itemBuilder: (context, index) {
            final item = widget.entry.groupPhotos[index];
            final selected = _selectedPhotoIds.contains(item.assetId);
            return GestureDetector(
              onTap: () => _selectedPhotoIds.isNotEmpty
                  ? _togglePhotoSelection(item.assetId)
                  : _openPhotoViewer(
                      item,
                      groupPhotos: widget.entry.groupPhotos,
                    ),
              onLongPress: () => _togglePhotoSelection(item.assetId),
              child: FutureBuilder<Uint8List?>(
                future: _photoBytes[item.assetId],
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      bytes == null
                          ? const ColoredBox(color: Colors.black12)
                          : Image.memory(bytes, fit: BoxFit.cover),
                      if (selected)
                        const ColoredBox(
                          color: Color(0x66000000),
                          child: Center(
                            child: Icon(
                              Icons.check_circle,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            );
          },
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: AspectRatio(
        aspectRatio: 1,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: GestureDetector(
            onTap: () => _selectedPhotoIds.isNotEmpty
                ? _togglePhotoSelection(photo.assetId)
                : _openPhotoViewer(photo),
            onLongPress: () => _togglePhotoSelection(photo.assetId),
            child: FutureBuilder<Uint8List?>(
              future: _photoBytes[photo.assetId],
              builder: (context, snapshot) {
                final bytes = snapshot.data;
                return bytes == null
                    ? const ColoredBox(
                        color: Colors.black12,
                        child: Icon(Icons.photo_outlined, size: 48),
                      )
                    : Image.memory(bytes, fit: BoxFit.cover);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailValue(String value) =>
      Padding(padding: const EdgeInsets.only(top: 10), child: Text(value));

  Widget _timeValue(String value) => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 6),
    child: Text(
      value,
      style: const TextStyle(fontSize: 13, color: Colors.black45),
    ),
  );

  Widget _labeledField(
    String label,
    TextEditingController controller, {
    String? hintText,
  }) => Row(
    children: [
      SizedBox(
        width: 52,
        child: Text(
          label,
          style: const TextStyle(color: Color(0xff667085), fontSize: 14),
        ),
      ),
      Expanded(
        child: TextField(
          controller: controller,
          maxLines: 1,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: hintText,
            hintStyle: const TextStyle(fontSize: 14, color: Color(0xff9aa89a)),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 4,
            ),
            filled: true,
            fillColor: const Color(0xfffff3a3),
            border: InputBorder.none,
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final photo = widget.entry.photo;
    final isPhoto = photo != null;
    final isManual = widget.entry.manualRecord != null;
    final isGroup = widget.entry.groupPhotos.length > 1;
    final isEditableMemo =
        isPhoto || widget.entry.routePoint != null || isManual;
    return AlertDialog(
      scrollable: !isGroup,
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      content: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _timeValue(_dateTime(widget.entry.time)),
            if (isPhoto) _photoPreview(),
            if (isPhoto) const SizedBox(height: 6),
            _labeledField('제목', _title, hintText: '제목을 입력하세요'),
            const SizedBox(height: 6),
            if (isPhoto)
              _labeledField('장소', _placeController, hintText: '장소를 입력하세요')
            else if (isManual)
              _labeledField('장소', _placeController, hintText: '장소를 입력하세요')
            else if (!isManual)
              _detailValue(_place),
            if (isEditableMemo) const SizedBox(height: 6),
            if (isEditableMemo) ...[
              TextField(
                controller: _memo,
                minLines: 4,
                maxLines: 4,
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(
                  hintText: '메모를 입력하세요.',
                  hintStyle: TextStyle(color: Color(0xff8d8d73)),
                  contentPadding: EdgeInsets.all(10),
                  filled: true,
                  fillColor: Color(0xfffff3a3),
                  border: InputBorder.none,
                ),
              ),
            ] else if (widget.entry.title == '메모')
              _detailValue(widget.entry.detail),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        if (_selectedPhotoIds.isNotEmpty)
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              _RecordDialogResult(
                _RecordDialogAction.delete,
                photoIds: Set.unmodifiable(_selectedPhotoIds),
              ),
            ),
            child: const Text('선택 삭제'),
          )
        else
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              const _RecordDialogResult(_RecordDialogAction.delete),
            ),
            child: const Text('삭제'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _RecordDialogResult(
              _RecordDialogAction.save,
              title: _title.text,
              memo: isEditableMemo ? _memo.text : null,
              place: isPhoto || isManual ? _placeController.text : null,
            ),
          ),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

class _PhotoGroupViewer extends StatefulWidget {
  const _PhotoGroupViewer({required this.photos, required this.initialIndex});

  final List<PhotoMetadata> photos;
  final int initialIndex;

  @override
  State<_PhotoGroupViewer> createState() => _PhotoGroupViewerState();
}

class _PhotoGroupViewerState extends State<_PhotoGroupViewer> {
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<Uint8List?> _loadPhoto(PhotoMetadata photo) async {
    final asset = await AssetEntity.fromId(photo.assetId);
    return asset?.thumbnailDataWithSize(const ThumbnailSize(1600, 1600));
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black,
    child: SizedBox.expand(
      child: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            physics: const PageScrollPhysics(),
            itemCount: widget.photos.length,
            itemBuilder: (context, index) => FutureBuilder<Uint8List?>(
              future: _loadPhoto(widget.photos[index]),
              builder: (context, snapshot) {
                if (snapshot.data == null) {
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  );
                }
                return Center(
                  child: Image.memory(snapshot.data!, fit: BoxFit.contain),
                );
              },
            ),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close, color: Colors.white),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ManualRecordDraft {
  const _ManualRecordDraft({
    required this.recordedAt,
    required this.kind,
    required this.title,
    required this.place,
    required this.memo,
  });

  final DateTime recordedAt;
  final String kind;
  final String title;
  final String place;
  final String memo;
}

class _AddRecordDialog extends StatefulWidget {
  const _AddRecordDialog();

  @override
  State<_AddRecordDialog> createState() => _AddRecordDialogState();
}

class _AddRecordDialogState extends State<_AddRecordDialog> {
  final _recordedAt = DateTime.now();
  String _kind = 'memo';
  final _title = TextEditingController();
  final _place = TextEditingController();
  final _memo = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    _place.dispose();
    _memo.dispose();
    super.dispose();
  }

  Widget _timeValue(String value) => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 6),
    child: Text(
      value,
      style: const TextStyle(fontSize: 13, color: Colors.black45),
    ),
  );

  Widget _labeledField(
    String label,
    TextEditingController controller, {
    String? hintText,
  }) => Row(
    children: [
      SizedBox(
        width: 52,
        child: Text(
          label,
          style: const TextStyle(color: Color(0xff667085), fontSize: 14),
        ),
      ),
      Expanded(
        child: TextField(
          controller: controller,
          maxLines: 1,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: hintText,
            hintStyle: const TextStyle(fontSize: 14, color: Color(0xff9aa89a)),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 4,
            ),
            filled: true,
            fillColor: const Color(0xffd9ecff),
            border: InputBorder.none,
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    backgroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
    contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _timeValue(_dateTime(_recordedAt)),
        Row(
          children: [
            const SizedBox(
              width: 52,
              child: Text(
                '종류',
                style: TextStyle(color: Color(0xff667085), fontSize: 14),
              ),
            ),
            Expanded(
              child: SizedBox(
                height: 25,
                child: Container(
                  color: const Color(0xffd9ecff),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _kind,
                      isDense: true,
                      isExpanded: true,
                      style: const TextStyle(
                        color: Colors.black87,
                        fontSize: 14,
                      ),
                      items: const [
                        DropdownMenuItem(value: 'memo', child: Text('메모')),
                        DropdownMenuItem(value: 'payment', child: Text('결제')),
                        DropdownMenuItem(value: 'photo', child: Text('사진')),
                      ],
                      onChanged: (value) =>
                          setState(() => _kind = value ?? 'memo'),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _labeledField('제목', _title, hintText: '제목을 입력하세요'),
        const SizedBox(height: 6),
        _labeledField('장소', _place, hintText: '장소를 입력하세요'),
        const SizedBox(height: 6),
        TextField(
          controller: _memo,
          minLines: 4,
          maxLines: 4,
          style: const TextStyle(fontSize: 14),
          decoration: const InputDecoration(
            hintText: '메모를 입력하세요.',
            hintStyle: TextStyle(color: Color(0xff8d8d73)),
            contentPadding: EdgeInsets.all(10),
            filled: true,
            fillColor: Color(0xffd9ecff),
            border: InputBorder.none,
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          _ManualRecordDraft(
            recordedAt: _recordedAt,
            kind: _kind,
            title: _title.text,
            place: _place.text,
            memo: _memo.text,
          ),
        ),
        child: const Text('저장'),
      ),
    ],
  );
}

class _PhotoPickerDialog extends StatefulWidget {
  const _PhotoPickerDialog({required this.startDate, required this.endDate});

  final DateTime startDate;
  final DateTime endDate;

  @override
  State<_PhotoPickerDialog> createState() => _PhotoPickerDialogState();
}

class _PhotoPickerDialogState extends State<_PhotoPickerDialog> {
  List<AssetEntity> _assets = const [];
  final Set<String> _selected = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
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
      final start = DateTime(
        widget.startDate.year,
        widget.startDate.month,
        widget.startDate.day,
      );
      final end = DateTime(
        widget.endDate.year,
        widget.endDate.month,
        widget.endDate.day,
      );
      if (!mounted) return;
      setState(() {
        _assets = assets.where((asset) {
          final created = DateTime(
            asset.createDateTime.year,
            asset.createDateTime.month,
            asset.createDateTime.day,
          );
          return !created.isBefore(start) && !created.isAfter(end);
        }).toList();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('사진 선택'),
    content: SizedBox(
      width: 280,
      height: 420,
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : GridView.builder(
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
                          const ThumbnailSize(240, 240),
                        ),
                        builder: (context, snapshot) => snapshot.data == null
                            ? const ColoredBox(color: Colors.black12)
                            : Image.memory(snapshot.data!, fit: BoxFit.cover),
                      ),
                      if (selected)
                        const Align(
                          alignment: Alignment.topRight,
                          child: Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.check_circle, color: Colors.blue),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        onPressed: _selected.isEmpty
            ? null
            : () => Navigator.pop(
                context,
                _assets.where((asset) => _selected.contains(asset.id)).toList(),
              ),
        child: const Text('선택'),
      ),
    ],
  );
}

class TripMap extends StatefulWidget {
  const TripMap({
    super.key,
    required this.trip,
    required this.collapsedDates,
    required this.onRecordTap,
  });

  final Trip trip;
  final Set<DateTime> collapsedDates;
  final ValueChanged<int> onRecordTap;

  @override
  State<TripMap> createState() => _TripMapState();
}

class _TripMapState extends State<TripMap> {
  KakaoMapController? _controller;
  StreamSubscription<CameraMoveEndEvent>? _cameraMoveSubscription;
  StreamSubscription<LabelClickEvent>? _labelClickSubscription;
  RouteLocation? _currentLocation;
  LatLng? _cityCenter;
  List<_ScreenRouteSegment> _screenRouteSegments = const [];
  Size _mapSize = const Size(360, 210);
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

  bool get _hasExpandedDate {
    final dates = {
      ...widget.trip.routePoints.map((point) => _dateOnly(point.recordedAt)),
      ...widget.trip.photoMetadata.map((photo) => _dateOnly(photo.capturedAt)),
      ...widget.trip.manualRecords.map(
        (record) => _dateOnly(record.recordedAt),
      ),
    };
    return dates.any((date) => !widget.collapsedDates.contains(date));
  }

  List<LatLng> get _focusedRoutePoints {
    if (!_hasExpandedDate) return _routePoints;
    return widget.trip.routePoints
        .where(
          (point) =>
              !widget.collapsedDates.contains(_dateOnly(point.recordedAt)),
        )
        .map(
          (point) =>
              LatLng(latitude: point.latitude, longitude: point.longitude),
        )
        .toList();
  }

  List<LatLng> get _focusedPhotoPoints {
    if (!_hasExpandedDate) return _photoPoints;
    return widget.trip.photoMetadata
        .where(
          (photo) =>
              !widget.collapsedDates.contains(_dateOnly(photo.capturedAt)) &&
              photo.latitude != null &&
              photo.longitude != null,
        )
        .map(
          (photo) =>
              LatLng(latitude: photo.latitude!, longitude: photo.longitude!),
        )
        .toList();
  }

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
    final collapsedDatesChanged =
        oldWidget.collapsedDates.length != widget.collapsedDates.length ||
        oldWidget.collapsedDates.any(
          (date) => !widget.collapsedDates.contains(date),
        );
    if (oldWidget.trip != widget.trip || collapsedDatesChanged) _refreshMap();
  }

  @override
  void dispose() {
    _cameraMoveSubscription?.cancel();
    _labelClickSubscription?.cancel();
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
      points.addAll(_focusedRoutePoints);
      if (_isPast) points.addAll(_focusedPhotoPoints);
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
    await _registerRecordMarkerStyles(controller);
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
            'width': 4,
            'points': [
              for (final point in segment.points)
                {'latitude': point.latitude, 'longitude': point.longitude},
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

  Future<void> _registerRecordMarkerStyles(
    KakaoMapController controller,
  ) async {
    final records = <int, _NumberedMapRecord>{
      for (final record in _numberedMapRecords)
        if (record.number != null) record.number!: record,
    };
    for (final entry in records.entries) {
      final number = entry.key;
      const size = 48.0;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawCircle(
        const ui.Offset(size / 2, size / 2),
        size / 2,
        ui.Paint()..color = _dateColor(widget.trip.startDate, entry.value.time),
      );
      final text = TextPainter(
        text: TextSpan(
          text: '$number',
          style: const TextStyle(
            color: Color(0xffffffff),
            fontSize: 24,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(
        canvas,
        ui.Offset((size - text.width) / 2, (size - text.height) / 2),
      );
      final image = await recorder.endRecording().toImage(
        size.toInt(),
        size.toInt(),
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) continue;
      await controller.registerMarkerStyles(
        styles: [
          MarkerStyle(
            styleId: 'travel-record-number-$number',
            perLevels: [
              MarkerPerLevelStyle.fromBytes(
                bytes: bytes.buffer.asUint8List(
                  bytes.offsetInBytes,
                  bytes.lengthInBytes,
                ),
              ),
            ],
          ),
        ],
      );
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
    final latitudeScale =
        pixelsPerDegree * math.cos(center.latitude * math.pi / 180);
    return Offset(
      _mapSize.width / 2 +
          (point.longitude - center.longitude) * pixelsPerDegree,
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
      grouped
          .putIfAbsent(date, () => [])
          .add(LatLng(latitude: point.latitude, longitude: point.longitude));
    }
    final entries = grouped.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return [
      for (var index = 0; index < entries.length; index++)
        _RouteSegment(
          points: entries[index].value,
          color: _routeColor(widget.trip.startDate, entries[index].key),
        ),
    ];
  }

  List<_NumberedMapRecord> get _numberedMapRecords {
    final records = <_NumberedMapRecord>[];
    final photos = [...widget.trip.photoMetadata]
      ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
    PhotoMetadata? previous;
    for (final photo in photos) {
      final grouped =
          previous != null &&
          photo.capturedAt.difference(previous.capturedAt).abs() <=
              const Duration(minutes: 30) &&
          _photoDistanceMeters(photo, previous) <= 100;
      if (grouped) {
        previous = photo;
        continue;
      }
      records.add(
        _NumberedMapRecord(
          time: photo.capturedAt,
          position: photo.latitude == null || photo.longitude == null
              ? null
              : LatLng(latitude: photo.latitude!, longitude: photo.longitude!),
        ),
      );
      previous = photo;
    }
    records.addAll(
      widget.trip.manualRecords.map(
        (record) => _NumberedMapRecord(time: record.recordedAt),
      ),
    );
    records.sort((a, b) => a.time.compareTo(b.time));
    return [
      for (var index = 0; index < records.length; index++)
        records[index].copyWith(number: index + 1),
    ];
  }

  Future<void> _addTripMarkers(KakaoMapController controller) async {
    for (final record in _numberedMapRecords) {
      if (record.position == null ||
          widget.collapsedDates.contains(_dateOnly(record.time))) {
        continue;
      }
      await controller.addMarker(
        markerOption: MarkerOption(
          id: 'record-${record.number}',
          latLng: record.position!,
          rank: 10000,
          styleId: 'travel-record-number-${record.number}',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 210,
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
                        _labelClickSubscription = controller
                            .onLabelClickedStream
                            .listen((event) {
                              final match = RegExp(r'^record-(\d+)$')
                                  .firstMatch(event.labelId);
                              final number = int.tryParse(
                                match?.group(1) ?? '',
                              );
                              if (number != null) widget.onRecordTap(number);
                            });
                        await controller.addMarkerLayer(
                          layerId: KakaoMapController.defaultLabelLayerId,
                          zOrder: 1000,
                          clickable: true,
                        );
                        await _registerRecordMarkerStyles(controller);
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RouteSegment {
  const _RouteSegment({required this.points, required this.color});

  final List<LatLng> points;
  final Color color;
}

class _NumberedMapRecord {
  const _NumberedMapRecord({required this.time, this.position, this.number});

  final DateTime time;
  final LatLng? position;
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
      final path = Path()
        ..moveTo(segment.points.first.dx, segment.points.first.dy);
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

Future<PhotoMetadata> _photoMetadataFromAsset(
  AssetEntity asset,
  List<RoutePoint> routePoints,
) async {
  final file = await asset.file;
  final assetPosition = asset.latLng ?? await asset.latlngAsync();
  final fallbackPosition = _nearestRoutePosition(
    routePoints,
    asset.createDateTime,
  );
  return PhotoMetadata(
    assetId: asset.id,
    capturedAt: asset.createDateTime,
    filePath:
        file?.path ?? '${asset.relativePath ?? ''}${asset.title ?? asset.id}',
    latitude: assetPosition?.latitude ?? fallbackPosition?.latitude,
    longitude: assetPosition?.longitude ?? fallbackPosition?.longitude,
    mediaType: asset.type == AssetType.video ? 'video' : 'photo',
  );
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
      final photo = await _photoMetadataFromAsset(asset, _trip.routePoints);
      final index = metadata.indexWhere((item) => item.assetId == asset.id);
      if (index == -1) {
        metadata.add(photo);
      } else if (metadata[index].latitude == null && photo.latitude != null) {
        metadata[index] = PhotoMetadata(
          assetId: photo.assetId,
          capturedAt: photo.capturedAt,
          filePath: photo.filePath,
          title: metadata[index].title,
          memo: metadata[index].memo,
          place: metadata[index].place,
          mediaType: metadata[index].mediaType ?? photo.mediaType,
          latitude: photo.latitude,
          longitude: photo.longitude,
        );
      }
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
  static const _intervalKey = 'location_interval_minutes';
  final _preferences = SharedPreferencesAsync();
  final _locationService = LocationService();
  final _intervalController = TextEditingController(text: '10');
  bool _locationEnabled = true;
  bool _backgroundEnabled = false;
  int _intervalMinutes = 10;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final location = await _preferences.getBool(_locationKey);
    final background = await _preferences.getBool(_backgroundKey);
    final interval =
        await _preferences.getInt(_intervalKey) ??
        LocationService.defaultCollectionInterval.inMinutes;
    if (!mounted) return;
    setState(() {
      _locationEnabled = location ?? true;
      _backgroundEnabled = background ?? false;
      _intervalMinutes = interval.clamp(1, 1440);
      _intervalController.text = '$_intervalMinutes';
      _loading = false;
    });
  }

  Future<void> _saveInterval(String value) async {
    final interval = int.tryParse(value.trim());
    if (interval == null || interval < 1 || interval > 1440) {
      _intervalController.text = '$_intervalMinutes';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('수집 간격은 1~1440분 사이로 입력해주세요.')),
        );
      }
      return;
    }
    await _preferences.setInt(_intervalKey, interval);
    if (mounted) setState(() => _intervalMinutes = interval);
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
    _intervalController.dispose();
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
                  subtitle: Text('여행기간 중 $_intervalMinutes분 간격으로 위치를 저장합니다.'),
                ),
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('수집 간격'),
                  trailing: SizedBox(
                    width: 96,
                    child: TextField(
                      controller: _intervalController,
                      enabled: _locationEnabled,
                      textAlign: TextAlign.end,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(suffixText: '분'),
                      onSubmitted: _saveInterval,
                      onEditingComplete: () =>
                          _saveInterval(_intervalController.text),
                    ),
                  ),
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

Color _dateColor(DateTime tripStart, DateTime date) {
  const colors = [
    Color(0xff64b5f6),
    Color(0xff66bb6a),
    Color(0xffffb74d),
    Color(0xffba68c8),
    Color(0xffef5350),
    Color(0xff26a69a),
  ];
  final day = _dateOnly(date).difference(_dateOnly(tripStart)).inDays;
  return colors[(day < 0 ? 0 : day) % colors.length];
}

Color _routeColor(DateTime tripStart, DateTime date) =>
    Color.lerp(_dateColor(tripStart, date), Colors.black, 0.25)!;

bool _isVideo(PhotoMetadata photo) =>
    photo.mediaType == 'video' ||
    RegExp(
      r'\.(mp4|mov|m4v|avi|mkv)$',
      caseSensitive: false,
    ).hasMatch(photo.filePath);

LatLng? _nearestRoutePosition(List<RoutePoint> points, DateTime capturedAt) {
  final sameDay = points.where(
    (point) => _dateOnly(point.recordedAt) == _dateOnly(capturedAt),
  );
  RoutePoint? nearest;
  Duration? nearestDifference;
  for (final point in sameDay) {
    final difference = point.recordedAt.difference(capturedAt).abs();
    if (nearestDifference == null || difference < nearestDifference) {
      nearest = point;
      nearestDifference = difference;
    }
  }
  if (nearest == null || nearestDifference! > const Duration(minutes: 30)) {
    return null;
  }
  return LatLng(latitude: nearest.latitude, longitude: nearest.longitude);
}

double _photoDistanceMeters(PhotoMetadata a, PhotoMetadata b) {
  if (a.latitude == null ||
      a.longitude == null ||
      b.latitude == null ||
      b.longitude == null) {
    return double.infinity;
  }
  const radius = 6371000.0;
  final lat1 = a.latitude! * math.pi / 180;
  final lat2 = b.latitude! * math.pi / 180;
  final dLat = (b.latitude! - a.latitude!) * math.pi / 180;
  final dLon = (b.longitude! - a.longitude!) * math.pi / 180;
  final h =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return radius * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
}
