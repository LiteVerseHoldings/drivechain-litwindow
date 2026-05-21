import 'dart:async';

import 'package:bitwindow/providers/blockchain_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:sail_ui/gen/misc/v1/misc.pb.dart';
import 'package:sail_ui/rpcs/bitwindow_api.dart';

class OpReturnProvider extends ChangeNotifier {
  BitwindowRPC get api => GetIt.I.get<BitwindowRPC>();
  BlockchainProvider get blockchainProvider => GetIt.I.get<BlockchainProvider>();

  List<OPReturn> opReturns = [];
  bool initialized = false;
  String? error;

  bool _isFetching = false;

  OpReturnProvider() {
    blockchainProvider.addListener(fetch);
    fetch();
  }

  // Call this from anywhere to refresh indexed OP_RETURN graffiti.
  Future<void> fetch() async {
    if (_isFetching) {
      return;
    }
    _isFetching = true;
    error = null;

    bool dataChanged = false;

    try {
      final newOPReturns = await api.misc.listOPReturns();
      if (!listEquals(opReturns, newOPReturns)) {
        opReturns = newOPReturns;
        dataChanged = true;
      }
    } catch (e) {
      error = e.toString();
    }

    if (dataChanged || error != null) {
      if (dataChanged) {
        initialized = true;
      }

      if (dataChanged) {
        error = null;
      }

      notifyListeners();
    }

    _isFetching = false;
  }

  @override
  void dispose() {
    blockchainProvider.removeListener(fetch);
    super.dispose();
  }
}
