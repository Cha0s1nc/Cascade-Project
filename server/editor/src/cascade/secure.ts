// Whether the editor can run here. On a page browsers do not treat as secure
// (plain http at a network address) it cannot, and index.html stands in for the
// crypto.randomUUID such a page lacks, so main.tsx can say why instead of crashing.

/**
 * Why the editor cannot run here, or null. Its audio decoder runs threads, which
 * need a cross-origin isolated page, which needs a secure one: HTTPS, or this
 * machine (how Cascade's apps open it).
 */
export function cannotRun(): string | null {
	if (window.isSecureContext && self.crossOriginIsolated) return null;
	return window.isSecureContext
		? "The lyrics editor's audio needs this page served with Cascade Server's own headers, and something between here and the server removed them."
		: "The lyrics editor needs a secure page. Open it from Cascade on a computer, which finds its own way, or reach this server over HTTPS.";
}
