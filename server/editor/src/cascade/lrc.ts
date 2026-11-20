// Word-level Enhanced LRC ([mm:ss.xx]<mm:ss.xx>word...), what most .slrc files
// hold, and line-level LRC, into the editor's AMLL lines, so they open as TTML.
// The editor's own LRC reader keeps only line times.

import type {
	AmllLyricLine,
	AmllLyricResult,
	AmllLyricWord,
} from "$/modules/ttml-processor/types";

const LINE = /^\[(\d+):(\d+(?:\.\d+)?)\](.*)$/;
const WORD = /<(\d+):(\d+(?:\.\d+)?)>([^<]*)/g;

const ms = (m: string, s: string) =>
	Math.round((Number(m) * 60 + Number(s)) * 1000);

export function lrcToAmll(text: string): AmllLyricResult {
	const parsed: { start: number; words: AmllLyricWord[]; plain: string }[] = [];
	for (const raw of text.split(/\r?\n/)) {
		const m = LINE.exec(raw.trim());
		if (!m) continue;
		const start = ms(m[1], m[2]);
		const stamps = [...m[3].matchAll(WORD)];
		if (stamps.length === 0) {
			if (m[3].trim()) parsed.push({ start, words: [], plain: m[3].trim() });
			continue;
		}
		const words: AmllLyricWord[] = [];
		stamps.forEach((w, i) => {
			const next = stamps[i + 1];
			const startTime = ms(w[1], w[2]);
			if (!w[3].trim()) {
				// A bare stamp ends the word before it; a lone space joins it.
				if (words.length) words[words.length - 1].word += w[3];
				return;
			}
			words.push({
				word: w[3],
				startTime,
				endTime: next ? ms(next[1], next[2]) : startTime,
			});
		});
		if (words.length) parsed.push({ start, words, plain: "" });
	}

	const lyricLines: AmllLyricLine[] = parsed.map((l, i) => {
		const nextStart = parsed[i + 1]?.start;
		// A line-level line is one word, until the next line.
		const words = l.words.length
			? l.words
			: [{ word: l.plain, startTime: l.start, endTime: nextStart ?? l.start + 5000 }];
		const last = words[words.length - 1];
		if (last.endTime <= last.startTime)
			last.endTime = nextStart ?? last.startTime + 1000;
		return {
			words,
			translatedLyric: "",
			romanLyric: "",
			isBG: false,
			isDuet: false,
			startTime: words[0].startTime,
			endTime: last.endTime,
		};
	});
	return { lyricLines, metadata: [] };
}
