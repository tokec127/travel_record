class RoutePoint {
  const RoutePoint({
    required this.recordedAt,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
  });

  final DateTime recordedAt;
  final double latitude;
  final double longitude;
  final double accuracy;

  Map<String, Object?> toJson() => {
    'recordedAt': recordedAt.toIso8601String(),
    'latitude': latitude,
    'longitude': longitude,
    'accuracy': accuracy,
  };

  factory RoutePoint.fromJson(Map<String, dynamic> json) => RoutePoint(
    recordedAt: DateTime.parse(json['recordedAt'] as String),
    latitude: (json['latitude'] as num).toDouble(),
    longitude: (json['longitude'] as num).toDouble(),
    accuracy: (json['accuracy'] as num).toDouble(),
  );
}

class PhotoMetadata {
  const PhotoMetadata({
    required this.assetId,
    required this.capturedAt,
    required this.filePath,
    this.memo,
    this.latitude,
    this.longitude,
  });

  final String assetId;
  final DateTime capturedAt;
  final String filePath;
  final String? memo;
  final double? latitude;
  final double? longitude;

  Map<String, Object?> toJson() => {
    'assetId': assetId,
    'capturedAt': capturedAt.toIso8601String(),
    'filePath': filePath,
    'memo': memo,
    'latitude': latitude,
    'longitude': longitude,
  };

  factory PhotoMetadata.fromJson(Map<String, dynamic> json) => PhotoMetadata(
    assetId: json['assetId'] as String,
    capturedAt: DateTime.parse(json['capturedAt'] as String),
    filePath: json['filePath'] as String,
    memo: json['memo'] as String?,
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
    this.source = 'WWIS',
  });

  final DateTime date;
  final String weather;
  final double? minimumTemperature;
  final double? maximumTemperature;
  final String source;

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
    'source': source,
  };

  factory WeatherRecord.fromJson(Map<String, dynamic> json) => WeatherRecord(
    date: DateTime.parse(json['date'] as String),
    weather: json['weather'] as String,
    minimumTemperature: (json['minimumTemperature'] as num?)?.toDouble(),
    maximumTemperature: (json['maximumTemperature'] as num?)?.toDouble(),
    source: json['source'] as String? ?? 'WWIS',
  );
}

class Trip {
  const Trip({
    required this.id,
    required this.regionType,
    required this.regionName,
    required this.startDate,
    required this.endDate,
    this.countryName,
    this.routePoints = const [],
    this.photoMetadata = const [],
    this.hiddenPhotoIds = const [],
    this.weatherSummary,
    this.weatherDate,
    this.weatherRecords = const [],
  });

  final String id;
  final String regionType;
  final String regionName;
  final DateTime startDate;
  final DateTime endDate;
  final String? countryName;
  final List<RoutePoint> routePoints;
  final List<PhotoMetadata> photoMetadata;
  final List<String> hiddenPhotoIds;
  final String? weatherSummary;
  final DateTime? weatherDate;
  final List<WeatherRecord> weatherRecords;

  Trip copyWith({
    List<RoutePoint>? routePoints,
    List<PhotoMetadata>? photoMetadata,
    List<String>? hiddenPhotoIds,
    String? countryName,
    String? weatherSummary,
    DateTime? weatherDate,
    List<WeatherRecord>? weatherRecords,
  }) => Trip(
    id: id,
    regionType: regionType,
    regionName: regionName,
    startDate: startDate,
    endDate: endDate,
    countryName: countryName ?? this.countryName,
    routePoints: routePoints ?? this.routePoints,
    photoMetadata: photoMetadata ?? this.photoMetadata,
    hiddenPhotoIds: hiddenPhotoIds ?? this.hiddenPhotoIds,
    weatherSummary: weatherSummary ?? this.weatherSummary,
    weatherDate: weatherDate ?? this.weatherDate,
    weatherRecords: weatherRecords ?? this.weatherRecords,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'regionType': regionType,
    'regionName': regionName,
    'startDate': startDate.toIso8601String(),
    'endDate': endDate.toIso8601String(),
    'countryName': countryName,
    'routePoints': routePoints.map((point) => point.toJson()).toList(),
    'photoMetadata': photoMetadata.map((photo) => photo.toJson()).toList(),
    'hiddenPhotoIds': hiddenPhotoIds,
    'weatherSummary': weatherSummary,
    'weatherDate': weatherDate?.toIso8601String(),
    'weatherRecords': weatherRecords.map((item) => item.toJson()).toList(),
  };

  factory Trip.fromJson(Map<String, dynamic> json) => Trip(
    id: json['id'] as String,
    regionType: json['regionType'] as String,
    regionName: json['regionName'] as String,
    startDate: DateTime.parse(json['startDate'] as String),
    endDate: DateTime.parse(json['endDate'] as String),
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
  );
}
