// Which language is this lyric in? The detector itself is injected: the
// desktop uses franc (trigram matching, on device, no network), and Dart has no
// bundled equivalent, so a caller supplies one that answers ISO 639-3 or 'und'.
// Everything around it is ported from desktop/src/core/language.ts.

const _iso3ToIso1 = {
  'eng': 'en',
  'spa': 'es',
  'fra': 'fr',
  'deu': 'de',
  'jpn': 'ja',
  'kor': 'ko',
  'cmn': 'zh',
  'por': 'pt',
  'ita': 'it',
  'rus': 'ru',
  'arb': 'ar',
  'hin': 'hi',
  'ind': 'id',
  'nld': 'nl',
  'pol': 'pl',
  'tha': 'th',
  'tur': 'tr',
  'ukr': 'uk',
  'vie': 'vi',
};

/// Below this, trigram matching is guessing.
const languageMinChars = 24;

/// Best-guess language of [text], ISO 639-1 where known, else the raw 639-3, else '' when there is not enough signal. '' means "no idea", never "English". [detect] takes whitespace-normalized text and returns ISO 639-3 or 'und'.
String detectLanguage(String text, String Function(String text) detect) {
  final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.length < languageMinChars) return '';
  final iso3 = detect(clean);
  if (iso3 == 'und') return '';
  return _iso3ToIso1[iso3] ?? iso3;
}

final _nonLatin = RegExp(
  r'[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}\p{Script=Hangul}\p{Script=Cyrillic}\p{Script=Arabic}\p{Script=Hebrew}\p{Script=Greek}\p{Script=Thai}\p{Script=Devanagari}]',
  unicode: true,
);

/// The text to detect a sheet's language from: lines in a non-Latin script when there are enough of them, else the whole sheet.
// ponytail: Latin-script languages mixed into English still go by the whole sheet.
String sheetSample(List<String> lines) {
  final filled = lines.map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  final foreign = filled.where((l) => _nonLatin.allMatches(l).length >= 2).toList();
  final pool = foreign.length >= (filled.length * 0.15 > 2 ? filled.length * 0.15 : 2) ? foreign : filled;
  final text = pool.join(' ');
  return text.length > 1000 ? text.substring(0, 1000) : text;
}

/// Whether to offer translation: the sheet's language is known and not English. Judges the whole sheet, not the first line.
bool shouldOfferTranslation(List<String> lines, String Function(String text) detect) {
  final lang = detectLanguage(sheetSample(lines), detect);
  return lang != '' && lang != 'en';
}
