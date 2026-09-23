import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConfig {
  static Future<void> load() => dotenv.load(fileName: '.env');

  static String get googleMapsApiKey => dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '';

  static String get kakaoNativeAppKey => dotenv.env['KAKAO_NATIVE_APP_KEY'] ?? '';

  static String get worldWeatherServiceApiKey =>
      dotenv.env['WORLD_WEATHER_SERVICE_API_KEY'] ?? '';

  static String get yahooWeatherApiKey => dotenv.env['YAHOO_WEATHER_API_KEY'] ?? '';

  static String get firebaseApiKey => dotenv.env['FIREBASE_API_KEY'] ?? '';
}
