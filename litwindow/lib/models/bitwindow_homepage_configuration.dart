import 'package:sail_ui/sail_ui.dart';

class BitwindowHomepageConfiguration {
  static HomepageConfiguration get defaultConfiguration {
    return HomepageConfiguration(
      widgets: [
        HomepageWidgetConfig(widgetId: 'block_progression'),
        HomepageWidgetConfig(widgetId: 'fireplace_stats'),
        HomepageWidgetConfig(widgetId: 'latest_transactions'),
        HomepageWidgetConfig(widgetId: 'latest_blocks'),
      ],
    );
  }
}
