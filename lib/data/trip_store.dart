import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/trip.dart';

class TripStore {
  TripStore._({SharedPreferencesAsync? preferences})
    : _preferences = preferences;

  static const _key = 'trips';
  final SharedPreferencesAsync? _preferences;
  final List<Trip> _memoryTrips = [];
  Future<void> _saveQueue = Future<void>.value();

  factory TripStore.memory() => TripStore._();

  static Future<TripStore> load() async =>
      TripStore._(preferences: SharedPreferencesAsync());

  Future<List<Trip>> readAll() async {
    final json = _preferences == null
        ? null
        : await _preferences!.getString(_key);
    if (json == null) return List.unmodifiable(_memoryTrips);

    final values = jsonDecode(json) as List<dynamic>;
    return values
        .map((value) => Trip.fromJson(value as Map<String, dynamic>))
        .toList();
  }

  Future<void> save(Trip trip) {
    final operation = _saveQueue.then((_) => _saveNow(trip));
    _saveQueue = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> _saveNow(Trip trip) async {
    final trips = await readAll();
    final index = trips.indexWhere((item) => item.id == trip.id);
    final updated = [...trips];
    if (index == -1) {
      updated.add(trip);
    } else {
      updated[index] = _merge(trips[index], trip);
    }

    if (_preferences == null) {
      _memoryTrips
        ..clear()
        ..addAll(updated);
    } else {
      await _preferences!.setString(
        _key,
        jsonEncode(updated.map((item) => item.toJson()).toList()),
      );
    }
  }

  Trip _merge(Trip current, Trip incoming) {
    final hidden = {...current.hiddenPhotoIds, ...incoming.hiddenPhotoIds};
    final photos = <String, PhotoMetadata>{
      for (final photo in current.photoMetadata) photo.assetId: photo,
    };
    for (final photo in incoming.photoMetadata) {
      final previous = photos[photo.assetId];
      final memo = photo.memo?.trim();
      photos[photo.assetId] =
          previous != null &&
              (memo == null || memo.isEmpty) &&
              previous.memo?.trim().isNotEmpty == true
          ? PhotoMetadata(
              assetId: photo.assetId,
              capturedAt: photo.capturedAt,
              filePath: photo.filePath,
              title: photo.title ?? previous.title,
              memo: previous.memo,
              place: photo.place ?? previous.place,
              mediaType: photo.mediaType ?? previous.mediaType,
              latitude: photo.latitude,
              longitude: photo.longitude,
            )
          : photo;
    }
    photos.removeWhere((id, _) => hidden.contains(id));

    final routeIndexes = <String, int>{};
    final routePoints = <RoutePoint>[];
    for (final point in [...current.routePoints, ...incoming.routePoints]) {
      final key =
          '${point.recordedAt.toIso8601String()}|${point.latitude}|${point.longitude}';
      final index = routeIndexes[key];
      if (index == null) {
        routeIndexes[key] = routePoints.length;
        routePoints.add(point);
      } else {
        routePoints[index] = point;
      }
    }
    routePoints.sort((a, b) => a.recordedAt.compareTo(b.recordedAt));

    final weatherByDate = <String, WeatherRecord>{
      for (final record in current.weatherRecords)
        record.date.toIso8601String().substring(0, 10): record,
    };
    for (final record in incoming.weatherRecords) {
      weatherByDate[record.date.toIso8601String().substring(0, 10)] = record;
    }
    final manualById = <String, ManualRecord>{
      for (final record in current.manualRecords) record.id: record,
    };
    for (final record in incoming.manualRecords) {
      manualById[record.id] = record;
    }

    return incoming.copyWith(
      routePoints: routePoints,
      photoMetadata: photos.values.toList(),
      hiddenPhotoIds: hidden.toList(),
      weatherSummary: incoming.weatherSummary ?? current.weatherSummary,
      weatherDate: incoming.weatherDate ?? current.weatherDate,
      weatherRecords: weatherByDate.values.toList(),
      manualRecords: manualById.values.toList(),
    );
  }
}
