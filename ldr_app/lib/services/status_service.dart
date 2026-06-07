import 'dart:async';
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

class StatusService {
  static final StatusService _instance = StatusService._internal();
  factory StatusService() => _instance;
  StatusService._internal();

  Timer? _syncTimer;
  final Battery _battery = Battery();
  final _supabase = Supabase.instance.client;

  // Start periodic sync (e.g. every 2 minutes while app is open)
  void startSync() {
    _syncTimer?.cancel();
    _syncNow();
    _syncTimer = Timer.periodic(const Duration(minutes: 2), (timer) {
      _syncNow();
    });
  }

  void stopSync() {
    _syncTimer?.cancel();
  }

  Future<void> _syncNow() async {
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    try {
      // 1. Get Battery
      final batteryLevel = await _battery.batteryLevel;
      final batteryState = await _battery.batteryState;
      String bStateStr = 'discharging';
      if (batteryState == BatteryState.charging) bStateStr = 'charging';
      if (batteryState == BatteryState.full) bStateStr = 'full';

      // 2. Get Location (if permissions granted)
      double? lat;
      double? lon;
      String? temp;
      String? condition;

      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (serviceEnabled) {
        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        
        if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
          try {
            Position position = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(accuracy: LocationAccuracy.low, timeLimit: Duration(seconds: 5))
            );
            lat = position.latitude;
            lon = position.longitude;

            // 3. Get Weather from Open-Meteo
            final weatherUrl = Uri.parse('https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current_weather=true');
            final response = await http.get(weatherUrl).timeout(const Duration(seconds: 5));
            if (response.statusCode == 200) {
              final data = jsonDecode(response.body);
              final current = data['current_weather'];
              temp = '${current['temperature']}°C';
              
              // Map WMO Weather codes
              int code = current['weathercode'];
              if (code == 0) condition = 'Clear sky';
              else if (code <= 3) condition = 'Partly cloudy';
              else if (code <= 48) condition = 'Fog';
              else if (code <= 67) condition = 'Rain';
              else if (code <= 77) condition = 'Snow';
              else if (code <= 82) condition = 'Rain showers';
              else if (code <= 86) condition = 'Snow showers';
              else if (code >= 95) condition = 'Thunderstorm';
              else condition = 'Unknown';
            }
          } catch (e) {
            debugPrint('Failed to get location/weather: $e');
          }
        }
      }

      // 4. Update Profile
      final updateData = {
        'last_seen': DateTime.now().toUtc().toIso8601String(),
        'battery_level': batteryLevel,
        'battery_state': bStateStr,
      };

      if (lat != null && lon != null) {
        updateData['latitude'] = lat;
        updateData['longitude'] = lon;
      }
      
      if (temp != null && condition != null) {
        updateData['weather_temp'] = temp;
        updateData['weather_condition'] = condition;
      }

      await _supabase.from('profiles').update(updateData).eq('id', user.id);

    } catch (e) {
      debugPrint('Status sync failed: $e');
    }
  }
}
