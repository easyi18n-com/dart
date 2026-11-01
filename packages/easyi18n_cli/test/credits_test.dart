import 'package:easyi18n_cli/src/credits.dart';
import 'package:test/test.dart';

void main() {
  group('parseCreditsToMc', () {
    test('null/empty → null', () {
      expect(parseCreditsToMc(null), isNull);
      expect(parseCreditsToMc('  '), isNull);
    });

    test('whole and decimal credits convert to mc', () {
      expect(parseCreditsToMc('500'), 500000);
      expect(parseCreditsToMc('0.5'), 500);
      expect(parseCreditsToMc('0.005'), 5);
      expect(parseCreditsToMc('0'), 0);
    });

    test('rejects negatives and non-numbers', () {
      expect(() => parseCreditsToMc('-1'), throwsFormatException);
      expect(() => parseCreditsToMc('abc'), throwsFormatException);
    });
  });

  group('formatCredits', () {
    test('renders mc as credits with one decimal', () {
      expect(formatCredits(0), '0');
      expect(formatCredits(426), '0.4');
      expect(formatCredits(200000), '200');
      expect(formatCredits(5000000), '5,000');
      expect(formatCredits(107336), '107.3');
    });

    test('tiny non-zero amounts never show as 0', () {
      expect(formatCredits(10), '<0.1');
      expect(formatCredits(-10), '-<0.1');
    });
  });
}
