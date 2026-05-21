import 'package:flutter_test/flutter_test.dart';
import 'package:sail_ui/sail_ui.dart';

void main() {
  group('formatBitcoin', () {
    test('formats zero LTC with a decimal point', () {
      expect(formatBitcoin(0), '0.00000000 LTC');
      expect(formatBitcoin(null), '0.00000000 LTC');
    });

    test('formats eight decimal LTC values without comma grouping', () {
      expect(formatBitcoin(1.23456789), '1.23456789 LTC');
      expect(formatBitcoin(-0.00000001), '-0.00000001 LTC');
    });
  });
}
