import 'package:bitwindow/models/bitwindow_homepage_configuration.dart';
import 'package:bitwindow/providers/bitwindow_settings_provider.dart';
import 'package:bitwindow/widgets/homepage_widget_catalog.dart';
import 'package:get_it/get_it.dart';
import 'package:sail_ui/sail_ui.dart';

class HomepageConfigurationSetting extends SettingValue<HomepageConfiguration> {
  @override
  String get key => 'homepage_configuration';

  HomepageConfigurationSetting({super.newValue});

  @override
  HomepageConfiguration defaultValue() => BitwindowHomepageConfiguration.defaultConfiguration;

  @override
  HomepageConfiguration? fromJson(String jsonString) {
    try {
      return HomepageConfiguration.fromJson(jsonString);
    } catch (e) {
      return null;
    }
  }

  @override
  String toJson() {
    return value.toJson();
  }

  @override
  SettingValue<HomepageConfiguration> withValue([HomepageConfiguration? value]) {
    return HomepageConfigurationSetting(newValue: value);
  }
}

class BitwindowHomepageProvider extends HomepageProvider {
  final ClientSettings _settings = GetIt.I.get<ClientSettings>();

  HomepageConfiguration _configuration = BitwindowHomepageConfiguration.defaultConfiguration;
  HomepageConfiguration _tempConfiguration = BitwindowHomepageConfiguration.defaultConfiguration;
  bool _isLoading = false;
  bool _hasUnsavedChanges = false;

  @override
  HomepageConfiguration get configuration => _configuration;
  @override
  HomepageConfiguration get tempConfiguration => _tempConfiguration;
  @override
  bool get isLoading => _isLoading;
  @override
  bool get hasUnsavedChanges => _hasUnsavedChanges;

  bool get isConfiguredAwayFromDefault {
    // Check if current configuration is different from default
    final defaultConfig = BitwindowHomepageConfiguration.defaultConfiguration;
    if (_configuration.widgets.length != defaultConfig.widgets.length) {
      return true;
    }
    for (int i = 0; i < _configuration.widgets.length; i++) {
      if (_configuration.widgets[i].widgetId != defaultConfig.widgets[i].widgetId) {
        return true;
      }
    }
    return false;
  }

  BitwindowHomepageProvider() {
    _loadConfiguration();
  }

  Future<void> _loadConfiguration() async {
    _isLoading = true;
    notifyListeners();

    try {
      final setting = HomepageConfigurationSetting();
      final loadedSetting = await _settings.getValue(setting);
      _configuration = loadedSetting.value;
      _tempConfiguration = _configuration;
    } catch (e) {
      _configuration = BitwindowHomepageConfiguration.defaultConfiguration;
      _tempConfiguration = _configuration;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  @override
  Future<void> saveConfiguration() async {
    _isLoading = true;
    notifyListeners();

    try {
      final setting = HomepageConfigurationSetting(newValue: _tempConfiguration);
      await _settings.setValue(setting);
      _configuration = _tempConfiguration;
      _hasUnsavedChanges = false;

      // Mark homepage as configured if it's different from default
      if (isConfiguredAwayFromDefault) {
        final bitwindowSettingsProvider = GetIt.I.get<BitwindowSettingsProvider>();
        await bitwindowSettingsProvider.markHomepageAsConfigured();
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  @override
  void addWidget(String widgetId) {
    _tempConfiguration = _tempConfiguration.addWidget(widgetId);
    _hasUnsavedChanges = true;
    notifyListeners();
  }

  @override
  void removeWidget(int index) {
    _tempConfiguration = _tempConfiguration.removeWidget(index);
    _hasUnsavedChanges = true;
    notifyListeners();
  }

  @override
  void reorderWidgets(int oldIndex, int newIndex) {
    _tempConfiguration = _tempConfiguration.reorderWidgets(oldIndex, newIndex);
    _hasUnsavedChanges = true;
    notifyListeners();
  }

  void updateWidgetSettings(int index, Map<String, dynamic> settings) {
    _tempConfiguration = _tempConfiguration.updateWidgetSettings(index, settings);
    _hasUnsavedChanges = true;
    notifyListeners();
  }

  @override
  void undoChanges() {
    _tempConfiguration = _configuration;
    _hasUnsavedChanges = false;
    notifyListeners();
  }

  void cancelChanges() {
    _tempConfiguration = _configuration;
    _hasUnsavedChanges = false;
    notifyListeners();
  }

  @override
  Map<String, HomepageWidgetInfo> getWidgetCatalog() {
    return HomepageWidgetCatalog.getCatalogMap();
  }
}
