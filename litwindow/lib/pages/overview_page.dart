import 'dart:async';
import 'dart:math';

import 'package:auto_route/auto_route.dart';
import 'package:bitwindow/env.dart';
import 'package:bitwindow/pages/explorer/block_explorer_dialog.dart';
import 'package:bitwindow/providers/blockchain_provider.dart';
import 'package:bitwindow/providers/homepage_provider.dart' as bitwindow;
import 'package:bitwindow/providers/op_return_provider.dart';
import 'package:bitwindow/widgets/homepage_widget_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:sail_ui/providers/price_provider.dart';
import 'package:sail_ui/sail_ui.dart';
import 'package:stacked/stacked.dart';

@RoutePage()
class OverviewPage extends StatefulWidget {
  const OverviewPage({super.key});

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  @override
  Widget build(BuildContext context) {
    return ViewModelBuilder<OverviewViewModel>.reactive(
      viewModelBuilder: () => OverviewViewModel(),
      builder: (context, viewModel, child) => QtPage(
        child: HomepageBuilder(
          configuration: viewModel.homepageConfiguration,
          widgetCatalog: HomepageWidgetCatalog.getCatalogMap(),
          isPreview: false,
        ),
      ),
    );
  }
}

class OverviewViewModel extends BaseViewModel {
  bitwindow.BitwindowHomepageProvider get _homepageProvider => GetIt.I.get<bitwindow.BitwindowHomepageProvider>();
  HomepageConfiguration get homepageConfiguration => _homepageProvider.configuration;

  OverviewViewModel() {
    _homepageProvider.addListener(notifyListeners);
  }

  @override
  void dispose() {
    _homepageProvider.removeListener(notifyListeners);
    super.dispose();
  }
}

class FireplaceViewModel extends BaseViewModel {
  final PriceProvider priceProvider = GetIt.I.get<PriceProvider>();
  final BitwindowRPC api = GetIt.I.get<BitwindowRPC>();
  final EnforcerRPC _enforcerRPC = GetIt.I<EnforcerRPC>();

  bool get loading => _enforcerRPC.initializingBinary;

  String get priceLastUpdated => priceProvider.priceAge;
  String get price => priceProvider.formattedPrice;

  Timer? _timer;

  FireplaceViewModel() {
    fetchFireplaceStats();
    priceProvider.addListener(_onPriceChanged);

    if (!Environment.isInTest) {
      _timer = Timer.periodic(
        Duration(seconds: 1),
        // notify listeners every second to update the last updated time
        (timer) => notifyListeners(),
      );
    }
  }

  GetFireplaceStatsResponse? stats;

  void _onPriceChanged() {
    fetchFireplaceStats();
    notifyListeners();
  }

  Future<void> fetchFireplaceStats() async {
    try {
      final response = await api.bitwindowd.getFireplaceStats();
      if (response.toDebugString() != stats?.toDebugString()) {
        stats = response;
        notifyListeners();
      }
    } catch (_) {
      // is a fine to swallow
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    priceProvider.removeListener(_onPriceChanged);
    super.dispose();
  }
}

class BlockProgressionBar extends StatelessWidget {
  const BlockProgressionBar({super.key});

  @override
  Widget build(BuildContext context) {
    return ViewModelBuilder<BlockProgressionViewModel>.reactive(
      viewModelBuilder: () => BlockProgressionViewModel(),
      builder: (context, model, child) {
        final theme = SailTheme.of(context);
        final current = model.currentHeight?.toDouble() ?? 0;
        final goal = max(model.headerHeight ?? model.currentHeight ?? 1, 1).toDouble();

        return Container(
          constraints: const BoxConstraints(minHeight: 72),
          decoration: BoxDecoration(
            color: theme.colors.backgroundSecondary,
            border: Border.all(color: theme.colors.border),
            borderRadius: SailStyleValues.borderRadius,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 820;
              final metrics = Wrap(
                spacing: 20,
                runSpacing: 6,
                alignment: compact ? WrapAlignment.start : WrapAlignment.end,
                children: [
                  _BlockProgressMetric(label: 'Current block', value: model.currentHeightLabel),
                  _BlockProgressMetric(label: 'Headers', value: model.headerHeightLabel),
                  _BlockProgressMetric(label: 'Last block', value: model.lastBlockLabel),
                ],
              );

              final progress = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      SailSVG.fromAsset(
                        SailSVGAsset.blocks,
                        color: theme.colors.text,
                        width: 14,
                      ),
                      const SizedBox(width: 8),
                      SailText.primary13('Block progression', bold: true),
                      const SizedBox(width: 10),
                      SailText.secondary12(model.statusLabel),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ProgressBar(
                    current: current,
                    goal: goal,
                  ),
                ],
              );

              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    progress,
                    const SizedBox(height: 10),
                    metrics,
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: progress),
                  const SizedBox(width: 24),
                  metrics,
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class BlockProgressionViewModel extends BaseViewModel {
  final BlockchainProvider blockchainProvider = GetIt.I.get<BlockchainProvider>();
  final SyncProvider syncProvider = GetIt.I.get<SyncProvider>();
  final BitcoinConfProvider confProvider = GetIt.I.get<BitcoinConfProvider>();

  BlockProgressionViewModel() {
    blockchainProvider.addListener(notifyListeners);
    syncProvider.addListener(notifyListeners);
    confProvider.addListener(notifyListeners);
  }

  SyncInfo? get _syncInfo => syncProvider.mainchainSyncInfo;

  Block? get _latestBlock {
    if (blockchainProvider.blocks.isEmpty) {
      return null;
    }
    return blockchainProvider.blocks.reduce((a, b) => a.height >= b.height ? a : b);
  }

  int? get currentHeight => _syncInfo?.progressCurrent.toInt() ?? _latestBlock?.height;
  int? get headerHeight {
    final headers = _syncInfo?.progressGoal.toInt();
    final current = currentHeight;
    if (headers == null && current == null) {
      return null;
    }
    return max(headers ?? 0, current ?? 0);
  }

  String get currentHeightLabel => _formatHeight(currentHeight);
  String get headerHeightLabel => _formatHeight(headerHeight);

  String get lastBlockLabel {
    final block = _latestBlock;
    if (block == null) {
      return 'Waiting';
    }
    return block.blockTime.toDateTime().toLocal().format();
  }

  String get statusLabel {
    if (syncProvider.mainchainError != null || blockchainProvider.error != null) {
      return 'Connection pending';
    }
    if (confProvider.network == BitcoinNetwork.BITCOIN_NETWORK_SIGNET &&
        blockchainProvider.peers.isEmpty) {
      return 'Waiting for signet peer or miner';
    }
    final syncInfo = _syncInfo;
    if (syncInfo == null) {
      return _latestBlock == null ? 'Waiting for Litecoin Core' : 'Latest indexed block';
    }
    if (confProvider.network == BitcoinNetwork.BITCOIN_NETWORK_SIGNET &&
        syncInfo.isSynced &&
        syncInfo.progressCurrent == 0) {
      return 'Signet ready, waiting for blocks';
    }
    return syncInfo.isSynced ? 'Synced' : 'Syncing';
  }

  String _formatHeight(int? value) {
    if (value == null) {
      return 'Loading';
    }
    return formatWithThousandSpacers(value);
  }

  @override
  void dispose() {
    blockchainProvider.removeListener(notifyListeners);
    syncProvider.removeListener(notifyListeners);
    confProvider.removeListener(notifyListeners);
    super.dispose();
  }
}

class _BlockProgressMetric extends StatelessWidget {
  final String label;
  final String value;

  const _BlockProgressMetric({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = SailTheme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 112),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SailText.secondary12(
            label,
            color: theme.colors.inactiveNavText,
          ),
          const SizedBox(height: 2),
          SailText.primary13(
            value,
            bold: true,
          ),
        ],
      ),
    );
  }
}

class FireplaceStats extends StatelessWidget {
  const FireplaceStats({super.key});

  @override
  Widget build(BuildContext context) {
    return ViewModelBuilder<FireplaceViewModel>.reactive(
      viewModelBuilder: () => FireplaceViewModel(),
      builder: (context, model, child) => FireplaceStatsView(
        priceLastUpdated: model.priceLastUpdated,
        price: model.price,
        stats: model.stats ?? GetFireplaceStatsResponse(),
        loading: model.loading,
      ),
    );
  }
}

class FireplaceStat extends StatelessWidget {
  final String title;
  final String subtitle;
  final String value;
  final SailSVGAsset icon;
  final bool bitcoinAmount;
  final bool loading;

  const FireplaceStat({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.icon,
    this.bitcoinAmount = false,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return SailCardStats(
      title: title,
      subtitle: subtitle,
      value: value,
      icon: icon,
      loading: LoadingDetails(
        enabled: loading,
        description: 'Waiting for enforcer to boot and wallet to sync..',
      ),
    );
  }
}

class TransactionsView extends StatelessWidget {
  const TransactionsView({super.key});

  @override
  Widget build(BuildContext context) {
    return ViewModelBuilder<TransactionsViewModel>.reactive(
      viewModelBuilder: () => TransactionsViewModel(),
      builder: (context, model, child) {
        return LayoutBuilder(
          builder: (context, constraints) {
            // Responsive columns based on width
            int crossAxisCount = (constraints.maxWidth / 600).ceil();
            double gridSpacing = SailStyleValues.padding16;
            double totalSpacing = gridSpacing * (crossAxisCount - 1);
            double cardWidth = (constraints.maxWidth - totalSpacing) / crossAxisCount;
            double desiredCardHeight = 300;

            double childAspectRatio = cardWidth / desiredCardHeight;

            List<Widget> cardList = [
              SailCard(
                bottomPadding: false,
                title: 'Latest Transactions',
                error: model.hasErrorForKey('blockchain') ? model.error('blockchain').toString() : null,
                child: SizedBox(
                  height: 300,
                  child: LatestTransactionTable(
                    entries: model.recentTransactions,
                  ),
                ),
              ),
              SailCard(
                title: 'Latest Blocks',
                bottomPadding: false,
                child: SizedBox(
                  height: 300,
                  child: LatestBlocksTable(
                    blocks: model.recentBlocks,
                  ),
                ),
              ),
            ];

            return GridView.count(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: gridSpacing,
              mainAxisSpacing: gridSpacing,
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              childAspectRatio: childAspectRatio,
              children: cardList,
            );
          },
        );
      },
    );
  }
}

class TransactionsViewModel extends BaseViewModel {
  final BlockchainProvider blockchainProvider = GetIt.I.get<BlockchainProvider>();
  final BalanceProvider balanceProvider = GetIt.I.get<BalanceProvider>();
  TransactionsViewModel() {
    balanceProvider.addListener(notifyListeners);
    blockchainProvider.addListener(notifyListeners);
  }

  void errorListener() {
    if (balanceProvider.error != null) {
      setErrorForObject('balance', balanceProvider.error);
    }
    if (blockchainProvider.error != null) {
      setErrorForObject('blockchain', blockchainProvider.error);
    }
  }

  List<Block> get recentBlocks => blockchainProvider.blocks;
  List<RecentTransaction> get recentTransactions => blockchainProvider.recentTransactions;
}

class QtSeparator extends StatelessWidget {
  final double width;

  const QtSeparator({
    super.key,
    this.width = double.infinity,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: width,
      ),
      child: Container(
        height: 1.5,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0.0, 0.35, 0.36, 1.0],
            colors: [
              Colors.grey,
              Colors.grey.withValues(alpha: 0.3),
              Colors.white,
              Colors.white,
            ],
          ),
        ),
      ),
    );
  }
}

class LatestTransactionTable extends StatefulWidget {
  final List<RecentTransaction> entries;

  const LatestTransactionTable({
    super.key,
    required this.entries,
  });

  @override
  State<LatestTransactionTable> createState() => _LatestTransactionTableState();
}

class _LatestTransactionTableState extends State<LatestTransactionTable> {
  String sortColumn = 'time';
  bool sortAscending = true;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    onSort(sortColumn);
  }

  void onSort(String column) {
    if (sortColumn == column) {
      sortAscending = !sortAscending;
    } else {
      sortColumn = column;
      sortAscending = true;
    }
    sortEntries();
    setState(() {});
  }

  void sortEntries() {
    widget.entries.sort((a, b) {
      dynamic aValue = '';
      dynamic bValue = '';

      switch (sortColumn) {
        case 'time':
          aValue = a.time.toDateTime().millisecondsSinceEpoch;
          bValue = b.time.toDateTime().millisecondsSinceEpoch;
          break;
        case 'fee':
          aValue = a.feeSats;
          bValue = b.feeSats;
          break;
        case 'txid':
          aValue = a.txid;
          bValue = b.txid;
          break;
        case 'size':
          aValue = a.virtualSize;
          bValue = b.virtualSize;
          break;
      }

      return sortAscending ? aValue.compareTo(bValue) : bValue.compareTo(aValue);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SailTable(
      getRowId: (index) => widget.entries[index].txid,
      headerBuilder: (context) => [
        SailTableHeaderCell(
          name: 'Time',
          onSort: () => onSort('time'),
        ),
        SailTableHeaderCell(
          name: 'Fee',
          onSort: () => onSort('fee'),
        ),
        SailTableHeaderCell(
          name: 'TxID',
          onSort: () => onSort('txid'),
        ),
        SailTableHeaderCell(
          name: 'Size',
          onSort: () => onSort('size'),
        ),
        SailTableHeaderCell(
          name: 'Height',
          onSort: () => onSort('block'),
        ),
      ],
      rowBuilder: (context, row, selected) {
        final entry = widget.entries[row];
        return [
          SailTableCell(value: entry.time.toDateTime().toLocal().toString()),
          SailTableCell(value: entry.feeSats.toString()),
          SailTableCell(value: entry.txid),
          SailTableCell(value: entry.virtualSize.toString()),
          SailTableCell(
            value: entry.confirmedInBlock == 0 ? '-' : entry.confirmedInBlock.toString(),
          ),
        ];
      },
      rowCount: widget.entries.length,
      emptyPlaceholder: 'No transactions yet',
      drawGrid: true,
      sortColumnIndex: ['time', 'fee', 'txid', 'size', 'height'].indexOf(sortColumn),
      sortAscending: sortAscending,
      onSort: (columnIndex, ascending) {
        onSort(['time', 'fee', 'txid', 'size', 'height'][columnIndex]);
      },
    );
  }
}

class LatestBlocksTable extends StatefulWidget {
  final List<Block> blocks;

  const LatestBlocksTable({
    super.key,
    required this.blocks,
  });

  @override
  State<LatestBlocksTable> createState() => _LatestBlocksTableState();
}

class _LatestBlocksTableState extends State<LatestBlocksTable> {
  String sortColumn = 'time';
  bool sortAscending = true;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    onSort(sortColumn);
  }

  void onSort(String column) {
    if (sortColumn == column) {
      sortAscending = !sortAscending;
    } else {
      sortColumn = column;
      sortAscending = true;
    }
    sortEntries();
    setState(() {});
  }

  void sortEntries() {
    widget.blocks.sort((a, b) {
      dynamic aValue = '';
      dynamic bValue = '';

      switch (sortColumn) {
        case 'time':
          aValue = a.blockTime.toDateTime().millisecondsSinceEpoch;
          bValue = b.blockTime.toDateTime().millisecondsSinceEpoch;
          break;
        case 'height':
          aValue = a.height;
          bValue = b.height;
          break;
        case 'hash':
          aValue = a.hash;
          bValue = b.hash;
          break;
      }

      return sortAscending ? aValue.compareTo(bValue) : bValue.compareTo(aValue);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SailTable(
      getRowId: (index) => widget.blocks[index].hash,
      headerBuilder: (context) => [
        const SailTableHeaderCell(name: 'Time'),
        const SailTableHeaderCell(name: 'Height'),
        const SailTableHeaderCell(name: 'Block Hash'),
      ],
      rowBuilder: (context, row, selected) {
        final entry = widget.blocks[row];
        return [
          SailTableCell(value: entry.blockTime.toDateTime().toLocal().format()),
          SailTableCell(value: entry.height.toString()),
          SailTableCell(value: entry.hash),
        ];
      },
      rowCount: widget.blocks.length,
      emptyPlaceholder: 'No blocks yet',
      drawGrid: true,
      sortColumnIndex: ['time', 'height', 'hash'].indexOf(sortColumn),
      sortAscending: sortAscending,
      onSort: (columnIndex, ascending) {
        onSort(['time', 'height', 'hash'][columnIndex]);
      },
    );
  }
}

Future<void> displayGraffitiExplorerDialog(BuildContext context) async {
  await showDialog(
    context: context,
    builder: (context) => const Dialog(
      child: SizedBox(
        width: 900,
        height: 700,
        child: GraffitiExplorerView(),
      ),
    ),
  );
}

class NewGraffitiView extends StatelessWidget {
  const NewGraffitiView({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ViewModelBuilder<NewGraffitiViewModel>.reactive(
      viewModelBuilder: () => NewGraffitiViewModel(),
      builder: (context, viewModel, child) {
        return SailColumn(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: SailStyleValues.padding16,
          mainAxisSize: MainAxisSize.min,
          leadingSpacing: true,
          children: [
            SailTextField(
              label: 'Message',
              controller: viewModel.messageController,
              hintText: 'Enter a message',
              size: TextFieldSize.small,
            ),
            SailButton(
              label: 'Broadcast',
              onPressed: () => viewModel.createGraffiti(context),
              disabled: viewModel.messageController.text.isEmpty,
            ),
          ],
        );
      },
    );
  }
}

class NewGraffitiViewModel extends BaseViewModel {
  final TextEditingController messageController = TextEditingController();
  final OrchestratorWalletRPC _orchestratorWallet = GetIt.I<OrchestratorRPC>().wallet;
  WalletReaderProvider get _walletReader => GetIt.I<WalletReaderProvider>();

  NewGraffitiViewModel() {
    messageController.addListener(notifyListeners);
  }

  Future<void> createGraffiti(BuildContext context) async {
    if (messageController.text.isEmpty) {
      return;
    }

    try {
      final walletId = _walletReader.activeWalletId;
      if (walletId == null) throw Exception('No active wallet');

      final address = (await _orchestratorWallet.getNewAddress(walletId)).address;
      final txid = (await _orchestratorWallet.sendTransaction(
        walletId: walletId,
        destinations: {address: 10000}, // 0.0001 BTC
        opReturnMessage: messageController.text,
        feeRateSatPerVbyte: 1,
      )).txid;

      GetIt.I.get<NotificationProvider>().add(
        title: 'Graffiti broadcast',
        content: txid,
        dialogType: DialogType.success,
      );

      if (!context.mounted) return;
      messageController.clear();
    } catch (e) {
      if (!context.mounted) return;
      showSnackBar(context, 'could not broadcast graffiti: $e');
    }
  }

  @override
  void dispose() {
    messageController.removeListener(notifyListeners);
    messageController.dispose();
    super.dispose();
  }
}

class GraffitiExplorerView extends StatelessWidget {
  const GraffitiExplorerView({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ViewModelBuilder<GraffitiExplorerViewModel>.reactive(
      viewModelBuilder: () => GraffitiExplorerViewModel(),
      builder: (context, viewModel, child) {
        final hasFilters =
            viewModel.fromDate != null || viewModel.toDate != null || viewModel.searchController.text.isNotEmpty;

        return SailCard(
          title: 'Graffiti Explorer',
          subtitle: 'Browse blockchain graffiti and OP_RETURN data',
          widgetHeaderEnd: SailButton(
            label: 'New Graffiti',
            onPressed: () => newGraffitiDialog(context),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Calculate available height for the table (total height minus filter row and spacing)
              final tableHeight = constraints.maxHeight.isFinite ? constraints.maxHeight - 60 : 500.0;

              return SailColumn(
                spacing: SailStyleValues.padding16,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SailRow(
                    spacing: SailStyleValues.padding16,
                    children: [
                      Expanded(
                        flex: 2,
                        child: SailTextField(
                          hintText: 'Search by message or txid...',
                          controller: viewModel.searchController,
                          prefixIcon: Padding(
                            padding: const EdgeInsets.only(left: 12, right: 8),
                            child: SailSVG.fromAsset(
                              SailSVGAsset.search,
                              color: context.sailTheme.colors.textTertiary,
                            ),
                          ),
                          prefixIconConstraints: const BoxConstraints(maxHeight: 20, maxWidth: 40),
                        ),
                      ),
                      Expanded(
                        child: _DatePickerField(
                          label: 'From',
                          value: viewModel.fromDate,
                          onChanged: viewModel.setFromDate,
                          lastDate: viewModel.toDate ?? DateTime.now(),
                        ),
                      ),
                      Expanded(
                        child: _DatePickerField(
                          label: 'To',
                          value: viewModel.toDate,
                          onChanged: viewModel.setToDate,
                          firstDate: viewModel.fromDate,
                          lastDate: DateTime.now(),
                        ),
                      ),
                      if (hasFilters)
                        SailButton(
                          label: 'Clear',
                          variant: ButtonVariant.secondary,
                          onPressed: () async => viewModel.clearFilters(),
                        ),
                    ],
                  ),
                  SizedBox(
                    height: tableHeight,
                    child: GraffitiTable(
                      entries: viewModel.entries,
                      onSort: viewModel.onSort,
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Future<void> newGraffitiDialog(BuildContext context) async {
    await widgetDialog(
      context: context,
      title: 'New Graffiti',
      subtitle: 'Write whatever you want and broadcast it to the blockchain',
      child: const NewGraffitiView(),
    );
  }
}

class _DatePickerField extends StatelessWidget {
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final DateTime? firstDate;
  final DateTime? lastDate;

  const _DatePickerField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.firstDate,
    this.lastDate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = SailTheme.of(context);

    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: firstDate ?? DateTime(2009),
          lastDate: lastDate ?? DateTime.now(),
          builder: (context, child) {
            return Theme(
              data: Theme.of(context).copyWith(
                colorScheme: ColorScheme.dark(
                  primary: theme.colors.primary,
                  onPrimary: theme.colors.text,
                  surface: theme.colors.background,
                  onSurface: theme.colors.text,
                ),
                dialogTheme: DialogThemeData(backgroundColor: theme.colors.background),
              ),
              child: child!,
            );
          },
        );
        onChanged(picked);
      },
      borderRadius: SailStyleValues.borderRadius,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colors.backgroundSecondary,
          borderRadius: SailStyleValues.borderRadius,
          border: Border.all(color: theme.colors.border),
        ),
        child: SailRow(
          spacing: SailStyleValues.padding08,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            SailText.secondary12(
              value != null ? formatDate(value!) : label,
              color: value != null ? theme.colors.text : theme.colors.textTertiary,
            ),
            SailSVG.fromAsset(
              SailSVGAsset.calendar,
              color: theme.colors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

class GraffitiExplorerViewModel extends BaseViewModel {
  final OpReturnProvider _opReturnProvider = GetIt.I.get<OpReturnProvider>();
  final TextEditingController searchController = TextEditingController();

  String _sortColumn = 'time';
  bool _sortAscending = false;

  // Date range filter
  DateTime? _fromDate;
  DateTime? _toDate;

  DateTime? get fromDate => _fromDate;
  DateTime? get toDate => _toDate;

  List<OPReturn> get allEntries => _opReturnProvider.opReturns;

  List<OPReturn> get entries {
    var filtered = allEntries.where((entry) {
      // Apply search filter
      if (searchController.text.isNotEmpty) {
        final searchLower = searchController.text.toLowerCase();
        if (!entry.message.toLowerCase().contains(searchLower) && !entry.txid.toLowerCase().contains(searchLower)) {
          return false;
        }
      }

      // Apply date range filter
      final entryDate = entry.createTime.toDateTime();
      if (_fromDate != null) {
        final fromStart = DateTime(_fromDate!.year, _fromDate!.month, _fromDate!.day);
        if (entryDate.isBefore(fromStart)) {
          return false;
        }
      }
      if (_toDate != null) {
        final toEnd = DateTime(_toDate!.year, _toDate!.month, _toDate!.day, 23, 59, 59);
        if (entryDate.isAfter(toEnd)) {
          return false;
        }
      }

      return true;
    }).toList();

    // Apply sorting
    filtered.sort((a, b) {
      dynamic aValue = '';
      dynamic bValue = '';

      switch (_sortColumn) {
        case 'message':
          aValue = a.message;
          bValue = b.message;
          break;
        case 'time':
          aValue = a.createTime.toDateTime().millisecondsSinceEpoch;
          bValue = b.createTime.toDateTime().millisecondsSinceEpoch;
          break;
        case 'height':
          aValue = a.height;
          bValue = b.height;
          break;
        case 'txid':
          aValue = a.txid;
          bValue = b.txid;
          break;
      }

      return _sortAscending ? aValue.compareTo(bValue) : bValue.compareTo(aValue);
    });

    return filtered;
  }

  GraffitiExplorerViewModel() {
    _opReturnProvider.fetch();
    _opReturnProvider.addListener(notifyListeners);
    searchController.addListener(notifyListeners);
  }

  void setFromDate(DateTime? date) {
    _fromDate = date;
    notifyListeners();
  }

  void setToDate(DateTime? date) {
    _toDate = date;
    notifyListeners();
  }

  void clearFilters() {
    _fromDate = null;
    _toDate = null;
    searchController.clear();
    notifyListeners();
  }

  void onSort(String column) {
    if (_sortColumn == column) {
      _sortAscending = !_sortAscending;
    } else {
      _sortColumn = column;
      _sortAscending = column != 'time';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _opReturnProvider.removeListener(notifyListeners);
    searchController.removeListener(notifyListeners);
    searchController.dispose();
    super.dispose();
  }
}

class GraffitiTable extends StatelessWidget {
  final List<OPReturn> entries;
  final Function(String) onSort;

  const GraffitiTable({
    super.key,
    required this.entries,
    required this.onSort,
  });

  @override
  Widget build(BuildContext context) {
    final theme = SailTheme.of(context);
    final formatter = GetIt.I<FormatterProvider>();

    return ListenableBuilder(
      listenable: formatter,
      builder: (context, child) => SailTable(
        backgroundColor: theme.colors.backgroundSecondary,
        getRowId: (index) => entries[index].id.toString(),
        headerBuilder: (context) => [
          SailTableHeaderCell(name: 'Time', onSort: () => onSort('time')),
          SailTableHeaderCell(name: 'Height', onSort: () => onSort('height')),
          SailTableHeaderCell(name: 'TXID', onSort: () => onSort('txid')),
          SailTableHeaderCell(name: 'Message', onSort: () => onSort('message')),
        ],
        rowBuilder: (context, row, selected) {
          final entry = entries[row];
          return [
            SailTableCell(value: entry.createTime.toDateTime().toLocal().format()),
            SailTableCell(value: entry.height == 0 ? '-' : entry.height.toString()),
            SailTableCell(value: entry.txid),
            SailTableCell(value: entry.message),
          ];
        },
        rowCount: entries.length,
        emptyPlaceholder: 'No graffiti found',
        onSort: (columnIndex, ascending) {
          onSort(['message', 'time', 'height'][columnIndex]);
        },
      ),
    );
  }
}

class FireplaceStatsView extends StatelessWidget {
  final String priceLastUpdated;
  final String price;
  final GetFireplaceStatsResponse stats;
  final bool loading;

  const FireplaceStatsView({
    super.key,
    required this.priceLastUpdated,
    required this.price,
    required this.stats,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        int crossAxisCount = min(4, (constraints.maxWidth / 301).ceil());
        double gridSpacing = SailStyleValues.padding16;
        double totalSpacing = gridSpacing * (crossAxisCount - 1);
        double cardWidth = (constraints.maxWidth - totalSpacing) / crossAxisCount;
        double desiredCardHeight = 128; // Set your ideal card height here

        double childAspectRatio = cardWidth / desiredCardHeight;

        List<Widget> cardList = [
          FireplaceStat(
            title: 'Litecoin Price',
            subtitle: 'Last updated $priceLastUpdated',
            value: price,
            icon: SailSVGAsset.dollarSign,
            loading: loading,
          ),
          FireplaceStat(
            title: 'New transactions',
            value: stats.transactionCount24h.toString(),
            subtitle: 'Last 24 hours',
            icon: SailSVGAsset.iconTransactions,
            loading: loading,
          ),
          FireplaceStat(
            title: 'Number of blocks',
            value: stats.blockCount24h.toString(),
            subtitle: 'Last 24 hours',
            icon: SailSVGAsset.blocks,
            loading: loading,
          ),
        ];

        return GridView.count(
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: gridSpacing,
          mainAxisSpacing: gridSpacing,
          shrinkWrap: true,
          physics: NeverScrollableScrollPhysics(),
          childAspectRatio: childAspectRatio,
          children: cardList,
        );
      },
    );
  }
}
