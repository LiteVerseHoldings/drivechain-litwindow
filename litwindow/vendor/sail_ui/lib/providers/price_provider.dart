import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sail_ui/env.dart';
import 'package:sail_ui/extensions/formatting.dart';

/// Provider that fetches and maintains the current LTC/USD exchange rate.
class PriceProvider extends ChangeNotifier {
  double? ltcusd;
  DateTime? lastUpdated;
  String? error;
  bool isFetching = false;
  Timer? _fetchTimer;

  static const String _tickerUrl = 'https://api.coinbase.com/v2/prices/LTC-USD/spot';

  // Kept for older callers that still use legacy-named helpers in shared UI code.
  double? get btcusd => ltcusd;

  PriceProvider() {
    // Fetch once immediately
    fetch();
    // Then start periodic fetch
    _startFetchingTimer();
  }

  void _startFetchingTimer() {
    if (Environment.isInTest) {
      return;
    }

    _fetchTimer = Timer.periodic(Duration(seconds: 10), (timer) => fetch());
  }

  /// Fetch the latest LTC/USD spot price.
  Future<void> fetch() async {
    if (isFetching) {
      return;
    }

    isFetching = true;
    error = null;

    try {
      final response = await http.get(Uri.parse(_tickerUrl));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final priceData = data['data'];
        final amount = priceData is Map<String, dynamic> ? priceData['amount'] : null;
        final price = amount is String
            ? double.tryParse(amount)
            : amount is num
            ? amount.toDouble()
            : null;

        if (price != null) {
          ltcusd = price;
          lastUpdated = DateTime.now();
          error = null;
        } else {
          error = 'Invalid LTC price format from API';
        }
      } else {
        error = 'Failed to fetch price: HTTP ${response.statusCode}';
      }
    } catch (e) {
      error = 'Error fetching price: $e';
    } finally {
      isFetching = false;
      notifyListeners();
    }
  }

  /// Format the LTC price as a USD string.
  String get formattedPrice {
    if (ltcusd == null) {
      return 'Loading...';
    }

    if (ltcusd! >= 1000) {
      return '\$${formatWithThousandSpacers(ltcusd!.round())}';
    }
    return '\$${ltcusd!.toStringAsFixed(2)}';
  }

  /// Get the age of the last price update
  String get priceAge {
    if (lastUpdated == null) {
      return 'Never updated';
    }

    final now = DateTime.now();
    final difference = now.difference(lastUpdated!);

    if (difference.inSeconds < 60) {
      return '${difference.inSeconds}s ago';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else {
      return '${difference.inHours}h ago';
    }
  }

  double? ltcToUsd(double ltcAmount) {
    if (ltcusd == null) {
      return null;
    }
    return ltcAmount * ltcusd!;
  }

  /// Convert the app's native coin amount to USD.
  double? ltcAmountToUsd(double ltcAmount) {
    return ltcToUsd(ltcAmount);
  }

  double? usdToLtc(double usdAmount) {
    if (ltcusd == null || ltcusd == 0) {
      return null;
    }
    return usdAmount / ltcusd!;
  }

  /// Convert USD amount to the app's native coin.
  double? usdToLtcAmount(double usdAmount) {
    return usdToLtc(usdAmount);
  }

  @override
  void dispose() {
    _fetchTimer?.cancel();
    super.dispose();
  }
}
