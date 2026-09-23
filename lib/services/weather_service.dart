import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../models/trip.dart';

class WeatherService {
  static Future<List<_WwisCity>>? _citiesRequest;

  Future<WeatherRecord?> fetchRecord(
    Trip trip, {
    required DateTime date,
  }) async {
    late final List<_WwisCity> cities;
    try {
      cities = await (_citiesRequest ??= _loadCities());
    } catch (_) {
      _citiesRequest = null;
      rethrow;
    }
    if (cities.isEmpty) {
      _citiesRequest = null;
      throw const WeatherException('WWIS 도시 목록을 불러오지 못했습니다.');
    }
    final city = _findCity(cities, trip);
    if (city == null) return null;

    if (_dateOnly(date).isBefore(_dateOnly(DateTime.now()))) {
      return await _fetchHistoricalRecord(city, date);
    }

    final client = HttpClient();
    try {
      final request = await client
          .getUrl(
            Uri.parse(
              'https://worldweather.wmo.int/en/json/${city.id}_en.json',
            ),
          )
          .timeout(const Duration(seconds: 10));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw WeatherException('WWIS 예보 응답 오류(${response.statusCode})');
      }
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final forecast =
          (json['forecast'] as Map<String, dynamic>?)?['forecastDay'];
      if (forecast is! List || forecast.isEmpty) {
        if (_isToday(date)) return await _fetchTodayFallback(city, date);
        throw const WeatherException('예보 데이터가 없습니다.');
      }
      final targetDate = date.toIso8601String().substring(0, 10);
      final forecastDays = forecast.cast<Map<String, dynamic>>();
      final matchingDays = forecastDays
          .where((item) => item['forecastDate'] == targetDate)
          .toList();
      if (matchingDays.isEmpty && _isToday(date)) {
        return await _fetchTodayFallback(city, date);
      }
      final day = matchingDays.isEmpty
          ? forecastDays.first
          : matchingDays.first;
      if (day.isEmpty) return null;
      final providedDate = day['forecastDate'] as String?;
      final weather = day['weather'] as String?;
      final min = day['minTemp'] as String?;
      final max = day['maxTemp'] as String?;
      if (weather == null) throw const WeatherException('날씨 상태가 없습니다.');
      final dateLabel = providedDate == targetDate
          ? ''
          : ' · ${providedDate ?? '최근 제공일'} 기준';
      final proxyLabel = _isProxyCity(trip, city) ? ' · ${city.name} 기준' : '';
      return WeatherRecord(
        date: date,
        weather: '$weather$dateLabel$proxyLabel',
        minimumTemperature: double.tryParse(min ?? ''),
        maximumTemperature: double.tryParse(max ?? ''),
        morningWeather: weather,
        afternoonWeather: weather,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<WeatherRecord?> _fetchHistoricalRecord(
    _WwisCity city,
    DateTime date,
  ) async {
    final coordinates = _coordinates[city.name];
    if (coordinates == null) return null;
    final day = _formatDate(date);
    final client = HttpClient();
    try {
      final uri = Uri.https('archive-api.open-meteo.com', '/v1/archive', {
        'latitude': '${coordinates.$1}',
        'longitude': '${coordinates.$2}',
        'start_date': day,
        'end_date': day,
        'hourly': 'weather_code,temperature_2m',
        'timezone': 'auto',
      });
      final response = await (await client.getUrl(uri))
          .close()
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != HttpStatus.ok) return null;
      final json = jsonDecode(
        await response.transform(utf8.decoder).join(),
      ) as Map<String, dynamic>;
      final hourly = json['hourly'] as Map<String, dynamic>?;
      final times = (hourly?['time'] as List<dynamic>?)?.cast<String>();
      final codes = (hourly?['weather_code'] as List<dynamic>?)
          ?.map((value) => (value as num).toInt())
          .toList();
      final temperatures = (hourly?['temperature_2m'] as List<dynamic>?)
          ?.whereType<num>()
          .map((value) => value.toDouble())
          .toList();
      if (times == null || codes == null || times.isEmpty || codes.isEmpty) {
        return null;
      }
      int codeAt(int hour) {
        var best = 0;
        var difference = 24;
        for (
          var index = 0;
          index < times.length && index < codes.length;
          index++
        ) {
          final parsed = DateTime.tryParse(times[index]);
          if (parsed == null || parsed.day != date.day) continue;
          final currentDifference = (parsed.hour - hour).abs();
          if (currentDifference < difference) {
            best = codes[index];
            difference = currentDifference;
          }
        }
        return best;
      }

      final min = temperatures == null || temperatures.isEmpty
          ? null
          : temperatures.reduce((a, b) => math.min(a, b).toDouble());
      final max = temperatures == null || temperatures.isEmpty
          ? null
          : temperatures.reduce((a, b) => math.max(a, b).toDouble());
      return WeatherRecord(
        date: date,
        weather: _weatherName(codeAt(12)),
        minimumTemperature: min,
        maximumTemperature: max,
        morningWeather: _weatherName(codeAt(9)),
        afternoonWeather: _weatherName(codeAt(15)),
        source: '과거 날씨',
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  String _formatDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  DateTime _dateOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  Future<WeatherRecord> _fetchTodayFallback(
    _WwisCity city,
    DateTime date,
  ) async {
    final coordinates = _coordinates[city.name];
    if (coordinates == null) {
      throw const WeatherException('현재 날씨 좌표를 찾을 수 없습니다.');
    }
    final client = HttpClient();
    try {
      final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': '${coordinates.$1}',
        'longitude': '${coordinates.$2}',
        'current': 'weather_code',
        'daily': 'weather_code,temperature_2m_min,temperature_2m_max',
        'timezone': 'auto',
        'forecast_days': '1',
      });
      final response = await (await client.getUrl(uri))
          .close()
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != HttpStatus.ok) {
        throw WeatherException('현재 날씨 응답 오류(${response.statusCode})');
      }
      final json = jsonDecode(
        await response.transform(utf8.decoder).join(),
      ) as Map<String, dynamic>;
      final current = json['current'] as Map<String, dynamic>?;
      final daily = json['daily'] as Map<String, dynamic>?;
      final code = (current?['weather_code'] as num?)?.toInt();
      final min = (daily?['temperature_2m_min'] as List<dynamic>?)?.first;
      final max = (daily?['temperature_2m_max'] as List<dynamic>?)?.first;
      if (code == null) throw const WeatherException('현재 날씨 값이 없습니다.');
      return WeatherRecord(
        date: date,
        weather: _weatherName(code),
        minimumTemperature: (min as num?)?.toDouble(),
        maximumTemperature: (max as num?)?.toDouble(),
        source: '현재 날씨',
      );
    } finally {
      client.close(force: true);
    }
  }

  bool _isToday(DateTime date) {
    final today = DateTime.now();
    return date.year == today.year &&
        date.month == today.month &&
        date.day == today.day;
  }

  static String _weatherName(int code) {
    if (code == 0) return '맑음';
    if (code <= 3) return '구름';
    if (code >= 95) return '폭풍';
    if (code >= 71 && code <= 77) return '눈';
    if (code >= 51 && code <= 67 || code >= 80 && code <= 82) return '비';
    return '흐림';
  }

  static const _coordinates = {
    'Seoul': (37.5665, 126.9780),
    'Busan': (35.1796, 129.0756),
    'Daejeon': (36.3504, 127.3845),
    'Gwangju': (35.1595, 126.8526),
    'Gangneung': (37.7519, 128.8761),
    'Jeju': (33.4996, 126.5312),
  };

  static Future<List<_WwisCity>> _loadCities() async {
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(
            Uri.parse(
              'https://worldweather.wmo.int/en/json/full_city_list.txt',
            ),
          )
          .timeout(const Duration(seconds: 10));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != HttpStatus.ok) return const [];
      final text = await response.transform(utf8.decoder).join();
      return text
          .split('\n')
          .skip(1)
          .map(_WwisCity.fromLine)
          .whereType<_WwisCity>()
          .toList();
    } finally {
      client.close(force: true);
    }
  }

  _WwisCity? _findCity(List<_WwisCity> cities, Trip trip) {
    final name = _normalizeCity(
      _cityAliases[trip.regionName.trim()] ?? trip.regionName.trim(),
    );
    final country = trip.countryName == null
        ? null
        : _countryAliases[trip.countryName!.trim()] ?? trip.countryName!.trim();
    final matches = cities
        .where((city) => _normalizeCity(city.name) == name)
        .toList();
    if (matches.isEmpty) return null;
    return matches.firstWhere(
      (city) => country == null || city.country == country,
      orElse: () => matches.first,
    );
  }

  bool _isProxyCity(Trip trip, _WwisCity city) {
    final requested = _normalizeCity(trip.regionName);
    return requested != _normalizeCity(city.name);
  }

  static const _cityAliases = {
    '서울': 'Seoul',
    '서울특별시': 'Seoul',
    '인천': 'Seoul',
    '인천광역시': 'Seoul',
    '수원': 'Seoul',
    '수원시': 'Seoul',
    '성남': 'Seoul',
    '성남시': 'Seoul',
    '고양': 'Seoul',
    '고양시': 'Seoul',
    '용인': 'Seoul',
    '용인시': 'Seoul',
    '춘천': 'Seoul',
    '춘천시': 'Seoul',
    '원주': 'Seoul',
    '원주시': 'Seoul',
    '부산': 'Busan',
    '부산광역시': 'Busan',
    '대구': 'Busan',
    '대구광역시': 'Busan',
    '울산': 'Busan',
    '울산광역시': 'Busan',
    '창원': 'Busan',
    '창원시': 'Busan',
    '포항': 'Busan',
    '포항시': 'Busan',
    '대전': 'Daejeon',
    '대전광역시': 'Daejeon',
    '세종': 'Daejeon',
    '세종시': 'Daejeon',
    '세종특별자치시': 'Daejeon',
    '청주': 'Daejeon',
    '청주시': 'Daejeon',
    '광주': 'Gwangju',
    '광주광역시': 'Gwangju',
    '전주': 'Gwangju',
    '전주시': 'Gwangju',
    '목포': 'Gwangju',
    '목포시': 'Gwangju',
    '여수': 'Gwangju',
    '여수시': 'Gwangju',
    '강릉': 'Gangneung',
    '강릉시': 'Gangneung',
    '제주': 'Jeju',
    '제주시': 'Jeju',
    '제주특별자치도': 'Jeju',
  };

  static String _normalizeCity(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'(특별자치도|특별시|광역시|시|군)$'), '');

  static const _countryAliases = {
    '대한민국': 'Republic of Korea',
    '한국': 'Republic of Korea',
    '일본': 'Japan',
    '태국': 'Thailand',
    '홍콩': 'Hong Kong, China',
  };
}

class WeatherException implements Exception {
  const WeatherException(this.message);

  final String message;
}

class _WwisCity {
  const _WwisCity({
    required this.country,
    required this.name,
    required this.id,
  });

  final String country;
  final String name;
  final String id;

  static _WwisCity? fromLine(String line) {
    final values = line
        .split(';')
        .map((value) => value.trim().replaceAll('"', ''))
        .toList();
    if (values.length < 3 || values[2].isEmpty) return null;
    return _WwisCity(country: values[0], name: values[1], id: values[2]);
  }
}
