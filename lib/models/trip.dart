class RoutePoint {
  const RoutePoint({
    required this.recordedAt,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    this.memo,
  });

  final DateTime recordedAt;
  final double latitude;
  final double longitude;
  final double accuracy;
  final String? memo;

  Map<String, Object?> toJson() => {
    'recordedAt': recordedAt.toIso8601String(),
    'latitude': latitude,
    'longitude': longitude,
    'accuracy': accuracy,
    'memo': memo,
  };

  factory RoutePoint.fromJson(Map<String, dynamic> json) => RoutePoint(
    recordedAt: DateTime.parse(json['recordedAt'] as String),
    latitude: (json['latitude'] as num).toDouble(),
    longitude: (json['longitude'] as num).toDouble(),
    accuracy: (json['accuracy'] as num).toDouble(),
    memo: json['memo'] as String?,
  );
}

class PhotoMetadata {
  const PhotoMetadata({
    required this.assetId,
    required this.capturedAt,
    required this.filePath,
    this.title,
    this.memo,
    this.place,
    this.mediaType,
    this.latitude,
    this.longitude,
  });

  final String assetId;
  final DateTime capturedAt;
  final String filePath;
  final String? title;
  final String? memo;
  final String? place;
  final String? mediaType;
  final double? latitude;
  final double? longitude;

  Map<String, Object?> toJson() => {
    'assetId': assetId,
    'capturedAt': capturedAt.toIso8601String(),
    'filePath': filePath,
    'title': title,
    'memo': memo,
    'place': place,
    'mediaType': mediaType,
    'latitude': latitude,
    'longitude': longitude,
  };

  factory PhotoMetadata.fromJson(Map<String, dynamic> json) => PhotoMetadata(
    assetId: json['assetId'] as String,
    capturedAt: DateTime.parse(json['capturedAt'] as String),
    filePath: json['filePath'] as String,
    title: json['title'] as String?,
    memo: json['memo'] as String?,
    place: json['place'] as String?,
    mediaType: json['mediaType'] as String?,
    latitude: (json['latitude'] as num?)?.toDouble(),
    longitude: (json['longitude'] as num?)?.toDouble(),
  );
}

class WeatherRecord {
  const WeatherRecord({
    required this.date,
    required this.weather,
    this.minimumTemperature,
    this.maximumTemperature,
    this.morningWeather,
    this.afternoonWeather,
    this.source = 'WWIS',
  });

  final DateTime date;
  final String weather;
  final double? minimumTemperature;
  final double? maximumTemperature;
  final String? morningWeather;
  final String? afternoonWeather;
  final String source;

  String weatherAt(DateTime time) =>
      time.hour < 12 ? morningWeather ?? weather : afternoonWeather ?? weather;

  String get summary {
    final temperature = minimumTemperature == null || maximumTemperature == null
        ? ''
        : ' · 최저 ${minimumTemperature!.toStringAsFixed(0)}°C / 최고 ${maximumTemperature!.toStringAsFixed(0)}°C';
    return '$weather$temperature ($source)';
  }

  Map<String, Object?> toJson() => {
    'date': date.toIso8601String(),
    'weather': weather,
    'minimumTemperature': minimumTemperature,
    'maximumTemperature': maximumTemperature,
    'morningWeather': morningWeather,
    'afternoonWeather': afternoonWeather,
    'source': source,
  };

  factory WeatherRecord.fromJson(Map<String, dynamic> json) => WeatherRecord(
    date: DateTime.parse(json['date'] as String),
    weather: json['weather'] as String,
    minimumTemperature: (json['minimumTemperature'] as num?)?.toDouble(),
    maximumTemperature: (json['maximumTemperature'] as num?)?.toDouble(),
    morningWeather: json['morningWeather'] as String?,
    afternoonWeather: json['afternoonWeather'] as String?,
    source: json['source'] as String? ?? 'WWIS',
  );
}

class ManualRecord {
  const ManualRecord({
    required this.id,
    required this.recordedAt,
    required this.kind,
    required this.title,
    required this.memo,
    this.place,
  });

  final String id;
  final DateTime recordedAt;
  final String kind;
  final String title;
  final String memo;
  final String? place;

  Map<String, Object?> toJson() => {
    'id': id,
    'recordedAt': recordedAt.toIso8601String(),
    'kind': kind,
    'title': title,
    'memo': memo,
    'place': place,
  };

  factory ManualRecord.fromJson(Map<String, dynamic> json) => ManualRecord(
    id: json['id'] as String,
    recordedAt: DateTime.parse(json['recordedAt'] as String),
    kind: json['kind'] as String,
    title: json['title'] as String? ?? '',
    memo: json['memo'] as String? ?? '',
    place: json['place'] as String?,
  );
}

class PreparationFile {
  const PreparationFile({required this.name, required this.uri});

  final String name;
  final String uri;

  Map<String, String> toJson() => {'name': name, 'uri': uri};

  factory PreparationFile.fromJson(Map<String, dynamic> json) =>
      PreparationFile(name: json['name'] as String, uri: json['uri'] as String);
}

class Trip {
  const Trip({
    required this.id,
    required this.regionType,
    required this.regionName,
    required this.startDate,
    required this.endDate,
    this.title = '',
    this.countryName,
    this.routePoints = const [],
    this.photoMetadata = const [],
    this.hiddenPhotoIds = const [],
    this.weatherSummary,
    this.weatherDate,
    this.weatherRecords = const [],
    this.manualRecords = const [],
    this.preparationFiles = const {},
  });

  final String id;
  final String regionType;
  final String regionName;
  final DateTime startDate;
  final DateTime endDate;
  final String title;
  final String? countryName;
  final List<RoutePoint> routePoints;
  final List<PhotoMetadata> photoMetadata;
  final List<String> hiddenPhotoIds;
  final String? weatherSummary;
  final DateTime? weatherDate;
  final List<WeatherRecord> weatherRecords;
  final List<ManualRecord> manualRecords;
  final Map<String, List<PreparationFile>> preparationFiles;

  Trip copyWith({
    List<RoutePoint>? routePoints,
    List<PhotoMetadata>? photoMetadata,
    List<String>? hiddenPhotoIds,
    String? countryName,
    String? weatherSummary,
    DateTime? weatherDate,
    List<WeatherRecord>? weatherRecords,
    List<ManualRecord>? manualRecords,
    Map<String, List<PreparationFile>>? preparationFiles,
  }) => Trip(
    id: id,
    regionType: regionType,
    regionName: regionName,
    startDate: startDate,
    endDate: endDate,
    title: title,
    countryName: countryName ?? this.countryName,
    routePoints: routePoints ?? this.routePoints,
    photoMetadata: photoMetadata ?? this.photoMetadata,
    hiddenPhotoIds: hiddenPhotoIds ?? this.hiddenPhotoIds,
    weatherSummary: weatherSummary ?? this.weatherSummary,
    weatherDate: weatherDate ?? this.weatherDate,
    weatherRecords: weatherRecords ?? this.weatherRecords,
    manualRecords: manualRecords ?? this.manualRecords,
    preparationFiles: preparationFiles ?? this.preparationFiles,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'regionType': regionType,
    'regionName': regionName,
    'startDate': startDate.toIso8601String(),
    'endDate': endDate.toIso8601String(),
    'title': title,
    'countryName': countryName,
    'routePoints': routePoints.map((point) => point.toJson()).toList(),
    'photoMetadata': photoMetadata.map((photo) => photo.toJson()).toList(),
    'hiddenPhotoIds': hiddenPhotoIds,
    'weatherSummary': weatherSummary,
    'weatherDate': weatherDate?.toIso8601String(),
    'weatherRecords': weatherRecords.map((item) => item.toJson()).toList(),
    'manualRecords': manualRecords.map((item) => item.toJson()).toList(),
    'preparationFiles': preparationFiles.map(
      (key, files) =>
          MapEntry(key, files.map((file) => file.toJson()).toList()),
    ),
  };

  factory Trip.fromJson(Map<String, dynamic> json) => Trip(
    id: json['id'] as String,
    regionType: json['regionType'] as String,
    regionName: json['regionName'] as String,
    startDate: DateTime.parse(json['startDate'] as String),
    endDate: DateTime.parse(json['endDate'] as String),
    title: json['title'] as String? ?? '',
    countryName: json['countryName'] as String?,
    routePoints: (json['routePoints'] as List<dynamic>)
        .map((point) => RoutePoint.fromJson(point as Map<String, dynamic>))
        .toList(),
    photoMetadata: (json['photoMetadata'] as List<dynamic>? ?? [])
        .map((photo) => PhotoMetadata.fromJson(photo as Map<String, dynamic>))
        .toList(),
    hiddenPhotoIds: (json['hiddenPhotoIds'] as List<dynamic>? ?? [])
        .cast<String>(),
    weatherSummary: json['weatherSummary'] as String?,
    weatherDate: json['weatherDate'] == null
        ? null
        : DateTime.parse(json['weatherDate'] as String),
    weatherRecords: (json['weatherRecords'] as List<dynamic>? ?? [])
        .map((item) => WeatherRecord.fromJson(item as Map<String, dynamic>))
        .toList(),
    manualRecords: (json['manualRecords'] as List<dynamic>? ?? [])
        .map((item) => ManualRecord.fromJson(item as Map<String, dynamic>))
        .toList(),
    preparationFiles: _preparationFilesFromJson(json['preparationFiles']),
  );
}

Map<String, List<PreparationFile>> _preparationFilesFromJson(Object? value) {
  if (value is! Map<String, dynamic>) return {};
  return value.map((key, item) {
    final values = item is List ? item : [item];
    return MapEntry(
      key,
      values
          .map((file) => PreparationFile.fromJson(file as Map<String, dynamic>))
          .toList(),
    );
  });
}
