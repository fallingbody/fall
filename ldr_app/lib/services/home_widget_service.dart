import 'package:home_widget/home_widget.dart';

class HomeWidgetService {
  static const String appGroupId = 'group.com.ldr.app';
  static const String androidWidgetName = 'LdrWidgetProvider';

  static Future<void> initialize() async {
    await HomeWidget.setAppGroupId(appGroupId);
  }

  static Future<void> updatePartnerStatus(String statusMessage) async {
    await HomeWidget.saveWidgetData<String>('partner_status', statusMessage);
    await HomeWidget.updateWidget(
      name: androidWidgetName,
      iOSName: 'LdrWidget',
    );
  }
}
