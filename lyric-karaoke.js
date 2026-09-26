// Karaoke lyrics: the word spans and the fill that sweeps across them.
// Shared by the main window (the side panel and the Now Playing overlay, via
// renderer.js) and the miniplayer, so all three draw lyrics the same way.
// A plain script, loaded before either page's own; the styles are in
// styles/karaoke.css. Needs CascadeCore (build/core.js) loaded first.
//
// Everything here is global on purpose (both pages are global-scope scripts),
// so nothing else on either page may declare these names.

function _karaokeEsc(str) {
  return String(str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
}

function _wordProgress(w, nowTicks) {
  const ws = parseInt(w.dataset.ws)
  const we = w.dataset.we ? parseInt(w.dataset.we) : null
  if (nowTicks < ws) return 0
  if (!we || nowTicks >= we) return 100
  return (nowTicks - ws) / (we - ws) * 100
}

const _graphemes = new Intl.Segmenter(undefined, { granularity: 'grapheme' })
// Scripts written without spaces between words (see lyricWordSpans).
const _noSpaceScript = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Thai}\p{Script=Lao}\p{Script=Khmer}\p{Script=Myanmar}]/u

/** A karaoke line's word spans, shared by the side panel and the overlay.
 *  Background vocals (SpicyLyrics) get their own smaller row underneath,
 *  inside the same line element, so _paintWordSpans fills them on their own
 *  timings with no second loop.
 *
 *  Held notes get `emph`: they swell and glow while sung, after Apple Music.
 *  Only when `emphasis` is true, which callers set for SpicyLyrics lyrics
 *  (renderer.js: lyricsCredit set): its syllables carry real end times.
 *  Kugou stretches a word's end across any pause that follows it, and our own
 *  Enhanced LRC takes the next word's start as the end, so in both a word
 *  before a gap looks held when it is not. Trailing spaces go between word
 *  groups, never inside a span: an inline-block would swallow one. */
function lyricWordSpans(line, cls, emphasis) {
  const span = w => {
    const data = `data-ws="${w.Start}" data-we="${w.End ?? ''}"`
    if (emphasis && CascadeCore.isEmphasisWord(w)) {
      // Letter by letter, as Apple Music swells a held note: each letter is
      // its own span (see _paintWordSpans). Split into graphemes, not code
      // units, so an accented letter or an emoji stays in one piece.
      const text = w.Text.trimEnd()
      const letters = [..._graphemes.segment(text)].map(g => `<span class="emph-l">${_karaokeEsc(g.segment)}</span>`).join('')
      return `<span class="${cls} emph" ${data}>${letters}</span>`
    }
    return `<span class="${cls}" ${data}>${_karaokeEsc(w.Text.trimEnd())}</span>`
  }
  // Each whole word (its syllables up to a trailing space) sits in one
  // no-wrap span, with the space outside it. Chromium may break a line beside
  // an inline-block, so a held note's letters, or a syllable next to one,
  // wrapped mid-word ("y / eah").
  //
  // A word with a held syllable is held as a whole, as in Apple Music: one
  // .emph span from the first syllable's start to the last one's end, so the
  // fill sweeps evenly across it. Per syllable, "Disturbi" filled in 0.6s and
  // then one held "a" crawled for 1.5s, and only the "a" swelled.
  //
  // Only for scripts that put spaces between words. Japanese, Chinese and
  // Thai do not, so there the "word" up to a space is the whole line, and
  // holding it together overflowed the panel; their syllables wrap as the
  // script normally does. Over 30 characters is not a word either.
  const group = syls => {
    const whole = { Start: syls[0].Start, End: syls[syls.length - 1].End, Text: syls.map(w => w.Text).join('') }
    const held = emphasis && syls.length > 1 && syls.some(w => CascadeCore.isEmphasisWord(w)) && CascadeCore.isEmphasisWord(whole)
    const html = (held ? [whole] : syls).map(span).join('')
    const wordLike = !_noSpaceScript.test(whole.Text) && [...whole.Text.trim()].length <= 30
    return wordLike ? `<span class="lyric-wordgroup">${html}</span>` : html
  }
  const spans = words => {
    let out = '', syls = []
    for (const w of words) {
      syls.push(w)
      if (/\s$/.test(w.Text)) { out += group(syls) + ' '; syls = [] }
    }
    return out + (syls.length ? group(syls) : '')
  }
  const bg = line.Background?.length ? `<div class="lyric-bg">${spans(line.Background)}</div>` : ''
  return spans(line.Words) + bg
}

// Paint the karaoke fill across one line's word spans. Both callers below had
// this body byte for byte, differing only in element ids and class names.
//
// The --p write is skipped when the value has not changed: _wordProgress pins a
// word to 0 before it starts and 100 once it ends, so on any given frame every
// span but one is being rewritten with what it already holds - and each write
// invalidates a background-clip: text gradient sitting under a drop-shadow,
// which is the most expensive text paint in index.html.
function _paintWordSpans(line, nowTicks) {
  line?.querySelectorAll('.lyric-word, .ov-lyric-word').forEach(w => {
    // The fill has a soft edge 0.6em wide, as in Apple Music (the gradients in
    // styles/ put its colour stops at --p minus and plus 0.3em). Sliding the
    // edge's centre from -0.3em past the start to +0.3em past the end keeps an
    // unsung word fully dim and a sung one fully lit, instead of half an edge
    // hanging over each end.
    const prog = _wordProgress(w, nowTicks)
    const p = `calc(${prog.toFixed(2)}% + ${(prog * 0.006 - 0.3).toFixed(3)}em)`
    // A held note swells letter by letter, as in Apple Music: the word's
    // progress sweeps across its letters, each getting its own share of the
    // fill (--p). A letter the fill has reached is .lit, which starts its
    // rise animation in styles/lyrics.css (delayed peak, then a settle, held
    // until the line ends). Unlit again on a seek back, so it can replay.
    if (w.classList.contains('emph')) {
      const letters = w.children
      const n = letters.length
      for (let i = 0; i < n; i++) {
        const t = Math.max(0, Math.min(1, prog / 100 * n - i))
        const lp = `calc(${(t * 100).toFixed(2)}% + ${(t * 0.6 - 0.3).toFixed(3)}em)`
        const st = letters[i].style
        if (st.getPropertyValue('--p') !== lp) st.setProperty('--p', lp)
        const lit = t > 0
        if (letters[i].classList.contains('lit') !== lit) letters[i].classList.toggle('lit', lit)
      }
    }
    if (w.style.getPropertyValue('--p') !== p) w.style.setProperty('--p', p)
    const ws = parseInt(w.dataset.ws)
    const we = w.dataset.we ? parseInt(w.dataset.we) : null
    w.classList.toggle('active', nowTicks >= ws && (!we || nowTicks < we))
    // Reached by the fill: lifts slightly and stays up for the line
    // (styles/lyrics.css). Cleared again on a seek back.
    const sung = nowTicks >= ws
    if (w.classList.contains('sung') !== sung) w.classList.toggle('sung', sung)
  })
}
