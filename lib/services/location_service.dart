import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class LocationService {
  static const defaultCollectionInterval = Duration(minutes: 10);
  StreamSubscription<Position>? _automaticSubscription;

  Future<RouteLocation> currentLocation() async {
    await ensurePermission();

    final position = await Geolocator.getCurrentPosition();
    return RouteLocation(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracy: position.accuracy,
    );
  }

  Future<void> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationException('기기의 위치 서비스를 켜주세요.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw const LocationException('위치 권한이 거부되었습니다.');
    }
    if (permission == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
      throw const LocationException('설정에서 위치 권한을 허용해주세요.');
    }
  }

  Future<void> ensureBackgroundPermission() async {
    await ensurePermission();
    var permission = await Geolocator.checkPermission();
    if (permission != LocationPermission.always) {
      permission = await Geolocator.requestPermission();
    }
    if (permission != LocationPermission.always) {
      await Geolocator.openAppSettings();
      throw const LocationException('백그라운드 위치 권한을 항상 허용으로 설정해주세요.');
    }
  }

  Future<void> startAutomaticCollection({
    required void Function(RouteLocation location) onLocation,
    bool background = false,
    Duration interval = defaultCollectionInterval,
  }) async {
    if (background) {
      await ensureBackgroundPermission();
    } else {
      await ensurePermission();
    }
    await stopAutomaticCollection();

    final LocationSettings settings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        intervalDuration: interval,
        foregroundNotificationConfig: background
            ? const ForegroundNotificationConfig(
                notificationTitle: '여행기록 위치 수집 중',
                notificationText: '여행 기간 동안 설정된 간격으로 위치를 저장합니다.',
                enableWakeLock: false,
              )
            : null,
      );
    } else {
      settings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      );
    }

    _automaticSubscription = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen((position) {
      onLocation(
        RouteLocation(
          latitude: position.latitude,
          longitude: position.longitude,
          accuracy: position.accuracy,
        ),
      );
    });
  }

  Future<void> stopAutomaticCollection() async {
    await _automaticSubscription?.cancel();
    _automaticSubscription = null;
  }

  Future<void> dispose() => stopAutomaticCollection();
}

class RouteLocation {
  const RouteLocation({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
  });

  final double latitude;
  final double longitude;
  final double accuracy;
}

class LocationException implements Exception {
  const LocationException(this.message);

  final String message;
}
