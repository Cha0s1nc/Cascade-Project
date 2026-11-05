// Ported from desktop/test/language.test.ts. franc is not available in Dart,
// so the detector is a fake keyed on a script marker; the point here is the
// logic around it (thin input, ISO mapping, judging the whole sheet).
import 'package:cascade/core/language.dart';
import 'package:flutter_test/flutter_test.dart';

const es = 'Todos los seres humanos nacen libres e iguales en dignidad y derechos y, dotados como estan de razon y conciencia, deben comportarse fraternalmente los unos con los otros.';
const en = 'All human beings are born free and equal in dignity and rights. They are endowed with reason and conscience and should act towards one another in a spirit of brotherhood.';
const ja = 'すべての人間は、生まれながらにして自由であり、かつ、尊厳と権利とについて平等である。人間は、理性と良心とを授けられており、互いに同胞の精神をもって行動しなければならない。';

String fake(String text) {
  if (text.contains('Todos los seres')) return 'spa';
  if (text.contains('All human beings')) return 'eng';
  if (RegExp(r'[぀-ヿ]').hasMatch(text)) return 'jpn';
  return 'und';
}

void main() {
  test('maps ISO 639-3 to 639-1 where known, passes others through, und is empty', () {
    expect(detectLanguage(es, fake), 'es');
    expect(detectLanguage(en, fake), 'en');
    expect(detectLanguage(ja, fake), 'ja');
    expect(detectLanguage(es, (_) => 'xyz'), 'xyz');
    expect(detectLanguage(es, (_) => 'und'), '');
  });

  test('returns empty string rather than guessing on thin input', () {
    String boom(String _) => throw StateError('detector must not run');
    expect(detectLanguage('', boom), '');
    expect(detectLanguage('Oh', boom), '');
    expect(detectLanguage('   \n  \t ', boom), '');
    expect(detectLanguage('La la la', boom), '');
  });

  test('offers translation for non-English lyrics only', () {
    expect(shouldOfferTranslation([es], fake), isTrue);
    expect(shouldOfferTranslation([ja], fake), isTrue);
    expect(shouldOfferTranslation([en], fake), isFalse);
  });

  test('never offers translation when there is nothing to go on', () {
    expect(shouldOfferTranslation([], fake), isFalse);
    expect(shouldOfferTranslation(['', '', ''], fake), isFalse);
    expect(shouldOfferTranslation(['Ooh', 'Ahh'], fake), isFalse);
  });

  test('judges the whole sheet, not the first line', () {
    final lines = ['Bailando', ...es.split('. ')];
    expect(shouldOfferTranslation(lines, fake), isTrue);
  });

  test('normalises whitespace before measuring length', () {
    expect(detectLanguage('a\n\n   \t  b', (_) => 'spa'), '');
  });

  test('sheetSample prefers the non-Latin lines once there are enough of them', () {
    final lines = [...List.filled(8, 'An English line here'), 'すべての人間は', '自由であり、平等'];
    expect(sheetSample(lines), 'すべての人間は 自由であり、平等');
    expect(sheetSample(['One stray 漢字 in a credit', ...List.filled(8, 'English words')]), contains('English words'));
  });
}
