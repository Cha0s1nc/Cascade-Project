// Lyric parsing. No DOM, no Electron - this is one of the pieces that ports to
// webOS/Tizen/React Native as-is.
//
// All times are in "ticks": 100-nanosecond units, matching Jellyfin's convention.
// 1ms = 10,000 ticks.

export interface LyricWord {
  Start: number
  /** Filled in from the next word's Start; the final word of a line is resolved
   *  from the next line's Start once all lines are parsed. */
  End: number | null
  Text: string
}

export interface LyricLine {
  Start: number
  End: number | null
  Text: string
  /** null for plain LRC lines; populated for karaoke (word-level) formats. */
  Words: LyricWord[] | null
}

const TICKS_PER_MS = 10_000

/** 2s, used when the last line has no following line to borrow an end time from. */
const LAST_WORD_FALLBACK_TICKS = 20_000_000

function lrcTimeToTicks(mm: string, ss: string): number {
  return Math.round((parseInt(mm) * 60 + parseFloat(ss)) * 10_000_000)
}

/**
 * Parse standard LRC, or Enhanced LRC (karaoke word-level), into lyric lines.
 *
 * Standard:  [mm:ss.xx]text
 * Enhanced:  [mm:ss.xx]<mm:ss.xx>word<mm:ss.xx>word...
 */
export function parseLRC(text: string): LyricLine[] {
  const lines: LyricLine[] = []

  for (const raw of text.split('\n')) {
    // Fractional seconds are optional. Requiring them silently dropped every
    // `[mm:ss]` line - a common LRC style - so files written that way lost
    // most of their content with no error. Metadata tags ([ar:], [offset:])
    // still fail the \d+ minutes group and are skipped as before.
    const m = raw.match(/^\[(\d+):(\d+(?:\.\d+)?)\](.*)$/)
    if (!m) continue

    const startTicks = lrcTimeToTicks(m[1], m[2])
    const content = m[3]

    if (content.includes('<')) {
      const words: LyricWord[] = []
      // Same optional-decimal rule as the line timestamps above.
      const wordRe = /<(\d+):(\d+(?:\.\d+)?)>([^<\[]*)/g
      let wm: RegExpExecArray | null

      // Per-character sources (Chinese karaoke formats, .slrc) give every space its
      // own timestamped token. Those read as "symbols" below, and trimStart() would
      // delete them outright - collapsing the whole line into one run-on string.
      // Tracked separately so a bundled trailing space (per-word LRC: "<ts>word ")
      // still gets trimmed before punctuation, which is what trimEnd is there for.
      let pendingSpace = false

      while ((wm = wordRe.exec(content)) !== null) {
        const wText = wm[3]
        if (!wText) continue
        if (!wText.trim()) { pendingSpace = words.length > 0; continue }

        // Symbols/punctuation with no letters or digits - attach to previous word
        const isSymbol = !/[\p{L}\p{N}]/u.test(wText)
        if (isSymbol && words.length > 0 && !pendingSpace) {
          const prev = words[words.length - 1]
          prev.Text = prev.Text.trimEnd() + wText.trimStart()
        } else {
          if (pendingSpace) words[words.length - 1].Text += ' '
          words.push({ Start: lrcTimeToTicks(wm[1], wm[2]), End: null, Text: wText })
        }
        pendingSpace = false
      }

      for (let i = 0; i < words.length - 1; i++) words[i].End = words[i + 1].Start

      // Last word's End is filled in below - it needs the next line's start.
      const fullText = words.map(w => w.Text).join('').trim()
      if (fullText) {
        lines.push({ Start: startTicks, End: null, Text: fullText, Words: words.length ? words : null })
      }
    } else {
      const t2 = content.trim()
      if (t2) lines.push({ Start: startTicks, End: null, Text: t2, Words: null })
    }
  }

  // Fill in the end time for each line's last word using the next line's start.
  for (let i = 0; i < lines.length; i++) {
    const ws = lines[i].Words
    if (!ws?.length) continue
    const last = ws[ws.length - 1]
    if (last.End == null) {
      last.End = lines[i + 1]?.Start ?? (last.Start + LAST_WORD_FALLBACK_TICKS)
    }
  }

  return lines
}

/**
 * Parse decrypted Kugou KRC into lyric lines.
 *
 * Line:  [{line_start_ms},{line_duration_ms}]<word_offset_ms,word_duration_ms,0>text...
 * Word offsets are relative to the line start.
 */
export function parseKrc(krcText: string): LyricLine[] {
  const lines: LyricLine[] = []

  for (const rawLine of krcText.split('\n')) {
    const line = rawLine.trim()
    const lineMatch = line.match(/^\[(\d+),(\d+)\](.*)$/)
    if (!lineMatch) continue                       // skip [ti:], [ar:], [offset:] tags

    const lineStartMs = parseInt(lineMatch[1])
    const lineEndMs = lineStartMs + parseInt(lineMatch[2])
    const content = lineMatch[3]

    const wordRegex = /<(\d+),(\d+),\d+>([^<]*)/g
    const words: LyricWord[] = []
    let fullText = ''
    let wm: RegExpExecArray | null

    while ((wm = wordRegex.exec(content)) !== null) {
      const wOffMs = parseInt(wm[1])
      const wDurMs = parseInt(wm[2])
      const wText = wm[3]
      if (!wText) continue
      fullText += wText
      words.push({
        Start: (lineStartMs + wOffMs) * TICKS_PER_MS,
        End: (lineStartMs + wOffMs + wDurMs) * TICKS_PER_MS,
        Text: wText,
      })
    }

    fullText = fullText.trim()
    if (!fullText) continue
    lines.push({
      Start: lineStartMs * TICKS_PER_MS,
      End: lineEndMs * TICKS_PER_MS,
      Text: fullText,
      Words: words.length > 0 ? words : null,
    })
  }

  return lines
}

/**
 * Compare two lyric results by word overlap, to catch a source returning a
 * completely different song. Returns true when they plausibly match.
 */
export function lyricsTextMatch(
  a: { lines: LyricLine[] } | null | undefined,
  b: { lines: LyricLine[] } | null | undefined,
): boolean {
  if (!a || !b) return true

  const words = (r: { lines: LyricLine[] }) => new Set(
    r.lines.map(l => l.Text).join(' ').toLowerCase().match(/[a-z]{3,}/g) || []
  )

  const aw = words(a)
  const bw = words(b)

  // Skip the check when either side has too few Latin words (e.g. Japanese songs).
  if (aw.size < 5 || bw.size < 5) return true

  const inter = [...aw].filter(w => bw.has(w)).length

  // At least 25% of the smaller set must appear in the larger.
  return inter / Math.min(aw.size, bw.size) >= 0.25
}
