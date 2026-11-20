// Cascade's lyrics editor: how this page talks to the Cascade Server plugin that
// serves it (/CascadeServer/Editor/), through the editor routes beside it
// (/CascadeServer/EditorApi/). Every call carries the editor token in a header,
// never in the address, which proxies log. See docs/flutter-plan.md, Lyrics editor.

const TOKEN_HEADER = "X-Cascade-Editor";

declare global {
	interface Window {
		/** Handed over by a Cascade app's window before the page runs. */
		cascadeEditorToken?: string;
		/** desktop_webview_window's bridge to the app, in a Cascade app's window only. */
		desktopWebview?: { postMessage(name: string, data?: unknown): void };
	}
}

/** Who the lyrics belong to: this user's own copy, the ones saved for everyone, or none yet. */
export type Owner = "mine" | "everyone" | null;

export interface CascadeSong {
	itemId: string;
	title: string;
	artist: string;
	album: string;
	durationSec: number;
	/** The audio file's extension, so the decoder knows its kind. */
	ext: string;
	/** An administrator, who may save for everyone. */
	admin: boolean;
	owner: Owner;
	format: "ttml" | "lrc" | null;
	text: string | null;
}

let token: string | null = null;

const route = (path: string) =>
	new URL(`../EditorApi/${path}`, location.href).toString();

/** The song this page edits: ?item= in its address. */
export const itemId = new URLSearchParams(location.search).get("item");

/** In a Cascade app's window, rather than a browser tab. */
export const inApp = () =>
	typeof window.desktopWebview?.postMessage === "function";

/**
 * Gets an editor token. A Cascade app's window has one already. A browser uses
 * Jellyfin's web app's sign-in, which it keeps in this same server's storage;
 * "signin" when there is none to use.
 */
export async function startSession(): Promise<"ok" | "signin" | "error"> {
	if (window.cascadeEditorToken) {
		token = window.cascadeEditorToken;
		return "ok";
	}
	if (!itemId) return "error";
	let servers: { AccessToken?: string }[] = [];
	try {
		servers =
			JSON.parse(localStorage.getItem("jellyfin_credentials") ?? "{}")
				.Servers ?? [];
	} catch {}
	for (const s of servers) {
		if (!s.AccessToken) continue;
		const res = await fetch(
			route(`Session?itemId=${encodeURIComponent(itemId)}`),
			{
				method: "POST",
				headers: { Authorization: `MediaBrowser Token="${s.AccessToken}"` },
			},
		);
		if (res.ok) {
			token = (await res.json()).token;
			return "ok";
		}
	}
	return "signin";
}

/** A call to an editor route, with the token. */
export function call(path: string, init: RequestInit = {}): Promise<Response> {
	const headers = new Headers(init.headers);
	if (token) headers.set(TOKEN_HEADER, token);
	return fetch(route(path), { ...init, headers });
}

/** A failed call's message for a person. */
export async function errorOf(res: Response): Promise<string> {
	try {
		return (await res.json()).error ?? `The server answered ${res.status}.`;
	} catch {
		return `The server answered ${res.status}.`;
	}
}

/** Ends the session, even as the page goes away. */
export function endSession() {
	if (!token) return;
	fetch(route("Close"), {
		method: "POST",
		headers: { [TOKEN_HEADER]: token },
		keepalive: true,
	}).catch(() => {});
	token = null;
}

/** Asks the Cascade app to close this window. */
export function closeWindow() {
	window.desktopWebview?.postMessage("cascade-close", null);
}
