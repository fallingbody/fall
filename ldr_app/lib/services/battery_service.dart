import 'package:battery_plus/battery_plus.dart';

class BatteryService {
  final Battery _battery = Battery();

  Future<int> getBatteryLevel() async {
    return await _battery.batteryLevel;
  }

  Stream<BatteryState> getBatteryStateStream() {
    return _battery.onBatteryStateChanged;
  }
}
