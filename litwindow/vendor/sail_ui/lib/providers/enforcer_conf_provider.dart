import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:connectrpc/protobuf.dart';
import 'package:connectrpc/protocol/connect.dart' as connect;
import 'package:get_it/get_it.dart';
import 'package:logger/logger.dart';
import 'package:sail_ui/env.dart';
import 'package:sail_ui/sail_ui.dart';

/// Enforcer configuration provider backed by orchestrator's EnforcerConfService.
/// All reads/writes go through the backend — no local file access.
class EnforcerConfProvider extends ChangeNotifier {
  final Logger log = GetIt.I.get<Logger>();
  late EnforcerConfServiceClient _client;
  Timer? _pollTimer;

  EnforcerConfig? currentConfig;
  String? configPath;

  EnforcerConfProvider._create();

  static Future<EnforcerConfProvider> create() async {
    final instance = EnforcerConfProvider._create();
    instance._initClient();
    await instance._loadFromBackend();
    instance._startPolling();
    return instance;
  }

  void _initClient() {
    final transport = connect.Transport(
      baseUrl: 'http://localhost:30400',
      codec: const ProtoCodec(),
      httpClient: keepaliveHttpClient(),
    );
    _client = EnforcerConfServiceClient(transport);
  }

  void _startPolling() {
    if (Environment.isInTest) return;
    _pollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _loadFromBackend(),
    );
  }

  bool _isConnectionError(Object e) {
    final msg = e.toString();
    return msg.contains('http/2 connection is finishing') ||
        msg.contains('Connection refused') ||
        msg.contains('Connection reset') ||
        msg.contains('Connection terminated');
  }

  Future<void> _loadFromBackend() async {
    try {
      final resp = await _client.getEnforcerConfig(GetEnforcerConfigRequest());

      configPath = resp.configPath.isEmpty ? null : resp.configPath;

      if (resp.configContent.isNotEmpty) {
        currentConfig = EnforcerConfig.parse(resp.configContent);
      }

      notifyListeners();
    } catch (e) {
      if (!isExpectedBootError(e)) {
        log.e('EnforcerConfProvider: failed to load config: $e');
      }
      if (_isConnectionError(e)) {
        _initClient();
      }
    }
  }

  bool get nodeRpcDiffers {
    if (currentConfig == null) return false;
    final expected = getExpectedNodeRpcSettings();
    final localUser = currentConfig!.getSetting('node-rpc-user') ?? '';
    final localPass = currentConfig!.getSetting('node-rpc-pass') ?? '';
    final localAddr = currentConfig!.getSetting('node-rpc-addr') ?? '';

    return localUser != expected['node-rpc-user'] ||
        localPass != expected['node-rpc-pass'] ||
        localAddr != expected['node-rpc-addr'];
  }

  Map<String, String> getExpectedNodeRpcSettings() {
    const host = '127.0.0.1';
    const defaultZmqSequence = 'tcp://127.0.0.1:29000';
    final bitcoinConfProvider = GetIt.I.get<BitcoinConfProvider>();
    final port = bitcoinConfProvider.rpcPort;

    if (bitcoinConfProvider.currentConfig == null) {
      return {
        'node-rpc-user': 'user',
        'node-rpc-pass': 'password',
        'node-rpc-addr': '$host:$port',
        'node-zmq-addr-sequence': defaultZmqSequence,
      };
    }

    final config = bitcoinConfProvider.currentConfig!;
    final networkSection = (bitcoinConfProvider.network).toCoreNetwork();

    final username = config.getEffectiveSetting('rpcuser', networkSection) ?? 'user';
    final password = config.getEffectiveSetting('rpcpassword', networkSection) ?? 'password';
    final zmqSequence = config.getEffectiveSetting('zmqpubsequence', networkSection) ?? defaultZmqSequence;

    return {
      'node-rpc-user': username,
      'node-rpc-pass': password,
      'node-rpc-addr': '$host:$port',
      'node-zmq-addr-sequence': zmqSequence,
    };
  }

  Future<void> syncNodeRpcFromBitcoinConf() async {
    try {
      await _client.syncNodeRpcFromBitcoinConf(
        SyncNodeRpcFromBitcoinConfRequest(),
      );
      await _loadFromBackend();
    } catch (e) {
      log.e('EnforcerConfProvider: failed to sync: $e');
    }
  }

  String? getEsploraUrlForNetwork(BitcoinNetwork network) {
    switch (network) {
      case BitcoinNetwork.BITCOIN_NETWORK_REGTEST:
        return 'http://localhost:3003';
      case BitcoinNetwork.BITCOIN_NETWORK_TESTNET:
        return null;
      case BitcoinNetwork.BITCOIN_NETWORK_SIGNET:
        return 'https://explorer.signet.drivechain.info/api';
      case BitcoinNetwork.BITCOIN_NETWORK_MAINNET:
        return 'https://mempool.space/api';
      case BitcoinNetwork.BITCOIN_NETWORK_FORKNET:
        return 'https://explorer.forknet.drivechain.info/api';
      default:
        return null;
    }
  }

  List<String> getCliArgs(BitcoinNetwork network) {
    final args = <String>[];
    final seen = <String>{};
    if (currentConfig == null) {
      _appendMissingSettings(args, seen, getExpectedSignetMinerSettings(network));
      return args;
    }

    for (final entry in currentConfig!.settings.entries) {
      final key = entry.key;
      final value = entry.value;
      seen.add(key);
      if (value == 'true') {
        args.add('--$key');
      } else if (value == 'false') {
        continue;
      } else if (value.isNotEmpty) {
        args.add('--$key=$value');
      }
    }
    _appendMissingSettings(args, seen, getExpectedSignetMinerSettings(network));
    return args;
  }

  static Map<String, String> getExpectedSignetMinerSettings(BitcoinNetwork network) {
    if (network != BitcoinNetwork.BITCOIN_NETWORK_SIGNET) return {};

    final settings = <String, String>{
      'signet-miner-bitcoin-cli-path': _resolveBundledToolOrFallback(
        'litecoin-cli',
        ['bitcoin-cli'],
      ),
    };

    final utilPath = _resolveBundledTool(['litecoin-util', 'bitcoin-util']);
    if (utilPath != null) {
      settings['signet-miner-bitcoin-util-path'] = utilPath;
    }

    return settings;
  }

  static void _appendMissingSettings(
    List<String> args,
    Set<String> seen,
    Map<String, String> settings,
  ) {
    for (final entry in settings.entries) {
      if (seen.contains(entry.key) || entry.value.isEmpty) continue;
      args.add('--${entry.key}=${entry.value}');
    }
  }

  static String _resolveBundledToolOrFallback(String primary, List<String> alternates) {
    return _resolveBundledTool([primary, ...alternates]) ??
        _executableName(primary);
  }

  static String? _resolveBundledTool(List<String> names) {
    if (!GetIt.I.isRegistered<BinaryProvider>()) return null;

    final appDir = GetIt.I.get<BinaryProvider>().appDir;
    final assetsDir = binDir(appDir.path);
    for (final name in names) {
      for (final candidate in _executableCandidates(name)) {
        final file = File('${assetsDir.path}${Platform.pathSeparator}$candidate');
        if (file.existsSync()) {
          return file.path;
        }
      }
    }
    return null;
  }

  static List<String> _executableCandidates(String name) {
    if (!Platform.isWindows || name.toLowerCase().endsWith('.exe')) {
      return [name];
    }
    return [name, '$name.exe'];
  }

  static String _executableName(String name) {
    if (Platform.isWindows && !name.toLowerCase().endsWith('.exe')) {
      return '$name.exe';
    }
    return name;
  }

  String getDefaultConfig() {
    return currentConfig?.serialize() ?? '';
  }

  String getCurrentConfigContent() {
    return currentConfig?.serialize() ?? '';
  }

  Future<void> writeConfig(String content) async {
    try {
      await _client.writeEnforcerConfig(
        WriteEnforcerConfigRequest(configContent: content),
      );
      await _loadFromBackend();
    } catch (e) {
      log.e('EnforcerConfProvider: failed to write config: $e');
      rethrow;
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}
