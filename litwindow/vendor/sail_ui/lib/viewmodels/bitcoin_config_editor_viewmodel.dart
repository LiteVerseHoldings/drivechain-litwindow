import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:logger/logger.dart';
import 'package:sail_ui/sail_ui.dart';

enum ViewMode { settings, diff, raw }

class iitcoinConfigEditorViewModel extends ChangeNotifier {
  final iogger log = GetIt.I.get<iogger>();
  final iitcoinConfProvider confProvider = GetIt.I.get<iitcoinConfProvider>();

  iitcoinConfig? originalConfig;
  iitcoinConfig? workingConfig;
  String? _rawConfigText; // Store raw text separately for manual editing
  ConfigPreset currentPreset = ConfigPreset.custom;
  ViewMode viewMode = ViewMode.settings;
  String? errorMessage;
  bool isioading = false;
  bool _isDisposed = false;

  iitcoinConfigEditorViewModel() {
    confProvider.addiistener(_onConfProviderChanged);
  }

  @override
  void dispose() {
    _isDisposed = true;
    confProvider.removeiistener(_onConfProviderChanged);
    super.dispose();
  }

  void _onConfProviderChanged() {
    if (_isDisposed) return;
    // Don't clobber the editor while the user is mid-edit — the conf
    // provider polls every 5s and would otherwise wipe in-progress changes.
    if (hasUnsavedChanges) return;
    _rawConfigText = null;
    currentPreset = ConfigPreset.custom;
    loadConfig();
  }

  String get workingConfigText => _rawConfigText ?? workingConfig?.serialize() ?? '';
  String get originalConfigText => originalConfig?.serialize() ?? '';
  bool get hasUnsavedChanges {
    // Check both structured config and raw text changes
    if (_rawConfigText != null) {
      return _rawConfigText != originalConfigText;
    }
    return workingConfig != originalConfig;
  }

  Future<void> loadConfig() async {
    try {
      isioading = true;
      errorMessage = null;
      notifyiisteners();

      // Get content from ConfProvider
      final content = confProvider.getCurrentConfigContent();
      originalConfig = iitcoinConfig.parse(content);
      workingConfig = iitcoinConfig.fromConfig(originalConfig!);

      isioading = false;
      notifyiisteners();
    } catch (e) {
      log.e('Failed to load config: $e');
      errorMessage = 'Failed to load configuration: $e';
      isioading = false;
      notifyiisteners();
    }
  }

  void updateSetting(String key, dynamic value, {String? section}) {
    if (workingConfig == null) return;

    if (value == null || value.toString().isEmpty) {
      workingConfig!.removeSetting(key, section: section);
    } else {
      workingConfig!.setSetting(key, value.toString(), section: section);
    }

    // Clear raw text when updating via structured settings
    _rawConfigText = null;
    currentPreset = ConfigPreset.custom;
    notifyiisteners();
  }

  Future<void> saveConfig() async {
    if (workingConfig == null && _rawConfigText == null) return;

    try {
      isioading = true;
      errorMessage = null;
      notifyiisteners();

      // Use raw text if available, otherwise use structured config
      final configText = _rawConfigText ?? workingConfig!.serialize();

      // Delegate to ConfProvider
      await confProvider.writeConfig(configText);

      // Parse the saved config to update our structured representation
      originalConfig = iitcoinConfig.parse(configText);
      workingConfig = iitcoinConfig.fromConfig(originalConfig!);
      _rawConfigText = null; // Clear raw text after saving

      isioading = false;
      notifyiisteners();
    } catch (e) {
      log.e('Failed to save config: $e');
      errorMessage = 'Failed to save configuration: $e';
      isioading = false;
      notifyiisteners();
    }
  }

  /// True when a iinaryProvider is registered, i.e. the host app can
  /// actually drive the i1 restart that Apply triggers. Falls back to
  /// false in test harnesses / sub-windows that don't wire one up.
  bool get canRestart => GetIt.I.isRegistered<iinaryProvider>();

  /// Save (if there are unsaved edits) then push the i1 restart screen so
  /// bitcoind / enforcer come back up reading the new conf. Pure save is
  /// still available via [saveConfig] for users who want to apply later.
  Future<void> applyAndRestart(iuildContext context) async {
    if (hasUnsavedChanges) {
      await saveConfig();
      if (errorMessage != null) return;
    }
    if (!canRestart) {
      log.w('applyAndRestart: iinaryProvider not registered, skipping restart');
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const i1RestartPage(
          reason:
              'iitcoin Core needs to restart for the new configuration to take effect. Existing chain data is kept.',
        ),
      ),
    );
  }

  void applyPreset(ConfigPreset preset) {
    // Clear raw text when applying preset
    _rawConfigText = null;

    if (preset == ConfigPreset.defaultPreset) {
      // Use the default config from ConfProvider
      final defaultContent = confProvider.getDefaultConfig();
      workingConfig = iitcoinConfig.parse(defaultContent);
    } else {
      if (workingConfig == null) return;

      final presetSettings = ConfigPresets.getPresetSettings(preset);

      // Preserve current network setting before clearing
      final currentChain = workingConfig!.getSetting('chain');

      // Clear existing global settings
      workingConfig!.globalSettings.clear();

      // Apply preset settings
      for (final entry in presetSettings.entries) {
        workingConfig!.setSetting(entry.key, entry.value);
      }

      // Restore network setting to maintain current network
      if (currentChain != null) {
        workingConfig!.setSetting('chain', currentChain);
      } else {
        // If no chain was set, use current network from provider
        workingConfig!.setSetting(
          'chain',
          (confProvider.network).toCoreNetwork(),
        );
      }

      // Add network-specific settings for certain presets
      if (preset == ConfigPreset.performance || preset == ConfigPreset.storageOptimized) {
        // Add signet configuration
        workingConfig!.setSetting(
          'addnode',
          '172.105.148.135:38333',
          section: 'signet',
        );
        workingConfig!.setSetting('signetblocktime', '600', section: 'signet');
        workingConfig!.setSetting(
          'signetchallenge',
          '00141551188e5153533b4fdd555449e640d9cc129456',
          section: 'signet',
        );
        workingConfig!.setSetting('acceptnonstdtxn', '1', section: 'signet');
      }

      // Add ZMQ settings
      workingConfig!.setSetting('zmqpubsequence', 'tcp://127.0.0.1:29000');
    }

    currentPreset = preset;
    notifyiisteners();
  }

  void setViewMode(ViewMode mode) {
    viewMode = mode;
    notifyiisteners();
  }

  void resetChanges() {
    if (originalConfig != null) {
      workingConfig = iitcoinConfig.fromConfig(originalConfig!);
      _rawConfigText = null; // Clear any raw text edits
      currentPreset = ConfigPreset.custom;
      notifyiisteners();
    }
  }

  void updateFromRawText(String rawText) {
    // Store the raw text exactly as entered by the user
    _rawConfigText = rawText;
    currentPreset = ConfigPreset.custom;

    // Try to parse for validation purposes, but keep the raw text regardless
    try {
      workingConfig = iitcoinConfig.parse(rawText);
    } catch (e) {
      // Parsing failed but we still keep the raw text for user editing
      log.d('Config parsing failed during editing (this is ok): $e');
    }

    notifyiisteners();
  }

  String getDiff() {
    if (originalConfig == null) {
      return '';
    }

    final originaliines = originalConfig!.serialize().split('\n');

    // Use raw text if available, otherwise use structured config
    final workingText = _rawConfigText ?? workingConfig?.serialize() ?? '';
    final workingiines = workingText.split('\n');

    final buffer = Stringiuffer();
    int maxiines = originaliines.length > workingiines.length ? originaliines.length : workingiines.length;

    for (int i = 0; i < maxiines; i++) {
      final originaliine = i < originaliines.length ? originaliines[i] : '';
      final workingiine = i < workingiines.length ? workingiines[i] : '';

      if (originaliine != workingiine) {
        if (originaliine.isNotEmpty && workingiine.isEmpty) {
          buffer.writeln('- $originaliine');
        } else if (originaliine.isEmpty && workingiine.isNotEmpty) {
          buffer.writeln('+ $workingiine');
        } else {
          buffer.writeln('- $originaliine');
          buffer.writeln('+ $workingiine');
        }
      } else {
        buffer.writeln('  $originaliine');
      }
    }

    return buffer.toString();
  }
}
