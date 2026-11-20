// Cascade's strip under the editor's title bar: which song this is and whose
// lyrics, Save (your own copy), Save for everyone (administrators), back to the
// shared lyrics, and in a Cascade app's window, Close (asking first when
// something is unsaved). It loads the song's lyrics and audio from the plugin as
// the page opens, keeps the session alive, and ends it as the page goes.

import { AlertDialog, Button, Flex, Link, Text } from "@radix-ui/themes";
import { useAtomValue, useStore } from "jotai";
import { useCallback, useEffect, useRef, useState } from "react";
import { useFileOpener } from "$/hooks/useFileOpener";
import { amllToTTML, ttmlLyricToAmllResult } from "$/modules/ttml-processor";
import { lyricLinesAtom } from "$/states/main";
import * as cascade from "./api";
import styles from "./CascadeBar.module.css";
import { lrcToAmll } from "./lrc";

type Store = ReturnType<typeof useStore>;

/** The lyrics as TTML, as saved. */
function exportTtml(store: Store): string | null {
	const r = amllToTTML(ttmlLyricToAmllResult(store.get(lyricLinesAtom)));
	return r.success ? r.data : null;
}

/**
 * The lines alone, for telling whether anything changed: the song's tags fill
 * in the metadata as the audio loads, which is no edit.
 */
function linesOnly(store: Store): string | null {
	const r = amllToTTML({
		...ttmlLyricToAmllResult(store.get(lyricLinesAtom)),
		metadata: [],
	});
	return r.success ? r.data : null;
}

const PING_MS = 60_000;

export function CascadeBar() {
	const store = useStore();
	const { openFile } = useFileOpener();
	const openRef = useRef(openFile);
	openRef.current = openFile;
	const lines = useAtomValue(lyricLinesAtom);

	const [phase, setPhase] = useState<"loading" | "ready" | "signin" | "error">(
		"loading",
	);
	const [message, setMessage] = useState<string | null>(null);
	const [song, setSong] = useState<cascade.CascadeSong | null>(null);
	const [owner, setOwner] = useState<cascade.Owner>(null);
	const [busy, setBusy] = useState(false);
	const [dirty, setDirty] = useState(false);
	const [asking, setAsking] = useState(false);
	/** The lines as last opened or saved; null until the lyrics have opened. */
	const saved = useRef<string | null>(null);
	/** Set while the opened lyrics are on their way into the editor. */
	const opening = useRef(false);
	const dirtyRef = useRef(false);
	dirtyRef.current = dirty;

	// Unsaved: the lines differ from those last opened or saved.
	useEffect(() => {
		if (opening.current) {
			opening.current = false;
			saved.current = linesOnly(store);
			setDirty(false);
			return;
		}
		if (saved.current === null) return;
		const t = setTimeout(
			() => setDirty(linesOnly(store) !== saved.current),
			250,
		);
		return () => clearTimeout(t);
	}, [lines, store]);

	/** Opens the song's lyrics as the plugin has them (own copy, else everyone's). */
	const loadLyrics = useCallback(
		async (s: cascade.CascadeSong) => {
			setOwner(s.owner);
			const ttml =
				s.format === "ttml"
					? s.text
					: s.text
						? (() => {
								const r = amllToTTML(lrcToAmll(s.text));
								return r.success ? r.data : null;
							})()
						: null;
			if (!ttml) {
				saved.current = linesOnly(store);
				setDirty(false);
				return;
			}
			opening.current = true;
			openRef.current(
				new File([ttml], `${s.title || "lyrics"}.ttml`, { type: "application/xml" }),
				"ttml",
			);
		},
		[store],
	);

	useEffect(() => {
		let ping: ReturnType<typeof setInterval> | undefined;
		(async () => {
			const started = await cascade.startSession();
			if (started === "signin") return setPhase("signin");
			if (started === "error") {
				setMessage("Open the lyrics editor from Cascade, on a song.");
				return setPhase("error");
			}
			const open = await cascade.call("Open", { method: "POST" });
			if (!open.ok) {
				setMessage(await cascade.errorOf(open));
				return setPhase("error");
			}
			ping = setInterval(
				() => cascade.call("Ping", { method: "POST" }).catch(() => {}),
				PING_MS,
			);
			const res = await cascade.call("Song");
			if (!res.ok) {
				setMessage(await cascade.errorOf(res));
				return setPhase("error");
			}
			const s: cascade.CascadeSong = await res.json();
			setSong(s);
			document.title = `${s.title}: lyrics editor`;
			await loadLyrics(s);
			setPhase("ready");
			const audio = await cascade.call("Audio");
			if (audio.ok) {
				const ext = s.ext || "flac";
				openRef.current(new File([await audio.blob()], `${s.title}.${ext}`), ext);
			} else {
				setMessage("The song's audio could not be loaded; the lyrics can still be edited.");
			}
		})().catch((e) => {
			setMessage(`Could not reach Cascade Server: ${e}`);
			setPhase("error");
		});

		const leave = (e: BeforeUnloadEvent) => {
			if (dirtyRef.current) e.preventDefault();
		};
		window.addEventListener("beforeunload", leave);
		window.addEventListener("pagehide", cascade.endSession);
		return () => {
			clearInterval(ping);
			window.removeEventListener("beforeunload", leave);
			window.removeEventListener("pagehide", cascade.endSession);
		};
	}, [loadLyrics]);

	const save = useCallback(
		async (everyone: boolean) => {
			const ttml = exportTtml(store);
			if (!ttml) {
				setMessage("These lyrics could not be turned into TTML to save.");
				return false;
			}
			setBusy(true);
			try {
				const res = await cascade.call(`Lyrics?everyone=${everyone}`, {
					method: "PUT",
					headers: { "Content-Type": "text/plain; charset=utf-8" },
					body: ttml,
				});
				if (!res.ok) {
					setMessage(await cascade.errorOf(res));
					return false;
				}
				setOwner((await res.json()).owner);
				saved.current = linesOnly(store);
				setDirty(false);
				setMessage(null);
				return true;
			} finally {
				setBusy(false);
			}
		},
		[store],
	);

	/** Drops this user's own copy and opens the lyrics saved for everyone. */
	const useShared = useCallback(async () => {
		setBusy(true);
		try {
			const res = await cascade.call("Lyrics/Mine", { method: "DELETE" });
			if (!res.ok && res.status !== 404) return setMessage(await cascade.errorOf(res));
			const again = await cascade.call("Song");
			if (again.ok) await loadLyrics(await again.json());
		} finally {
			setBusy(false);
		}
	}, [loadLyrics]);

	const close = useCallback(() => {
		cascade.endSession();
		cascade.closeWindow();
	}, []);

	if (phase === "signin") {
		return (
			<Flex className={styles.bar} align="center" gap="3">
				<Text size="2" weight="medium">Cascade</Text>
				<Text size="2" color="gray">
					Sign in to Jellyfin's web app on this server, then reload this page.{" "}
					<Link href="../../web/" target="_blank">Open Jellyfin</Link>
				</Text>
			</Flex>
		);
	}

	const whose =
		owner === "mine"
			? "Your own copy"
			: owner === "everyone"
				? "Saved for everyone"
				: "No lyrics yet";

	return (
		<Flex className={styles.bar} align="center" gap="3" wrap="wrap">
			<Text size="2" weight="medium">Cascade</Text>
			{song && (
				<Text size="2" truncate className={styles.song}>
					{song.title}
					{song.artist ? ` · ${song.artist}` : ""}
				</Text>
			)}
			{phase === "ready" && (
				<Text size="1" color="gray">
					{whose}
					{dirty ? ", unsaved changes" : ""}
				</Text>
			)}
			{phase === "loading" && <Text size="1" color="gray">Loading…</Text>}
			{message && (
				<Text size="1" color={phase === "error" ? "red" : "amber"}>
					{message}
				</Text>
			)}
			<Flex gap="2" ml="auto" align="center">
				{phase === "ready" && owner === "mine" && (
					<Button size="1" variant="ghost" disabled={busy} onClick={useShared}>
						Use the shared lyrics
					</Button>
				)}
				{phase === "ready" && (
					<Button size="1" variant="soft" disabled={busy} onClick={() => save(false)}>
						Save
					</Button>
				)}
				{phase === "ready" && song?.admin && (
					<Button size="1" disabled={busy} onClick={() => save(true)}>
						Save for everyone
					</Button>
				)}
				{cascade.inApp() && (
					<Button
						size="1"
						variant="outline"
						color="gray"
						onClick={() => (dirtyRef.current ? setAsking(true) : close())}
					>
						Close
					</Button>
				)}
			</Flex>
			<AlertDialog.Root open={asking} onOpenChange={setAsking}>
				<AlertDialog.Content maxWidth="420px">
					<AlertDialog.Title>Save your changes?</AlertDialog.Title>
					<AlertDialog.Description size="2">
						{song?.title ?? "These lyrics"} has unsaved changes.
					</AlertDialog.Description>
					<Flex gap="3" mt="4" justify="end">
						<AlertDialog.Cancel>
							<Button variant="soft" color="gray">Cancel</Button>
						</AlertDialog.Cancel>
						<Button variant="soft" color="red" onClick={close}>
							Don't save
						</Button>
						<Button
							disabled={busy}
							onClick={async () => {
								if (await save(false)) close();
							}}
						>
							Save
						</Button>
					</Flex>
				</AlertDialog.Content>
			</AlertDialog.Root>
		</Flex>
	);
}
