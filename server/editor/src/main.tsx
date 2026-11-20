/*
 * Copyright 2023-2025 Steve Xiao (stevexmh@qq.com) and contributors.
 *
 * 本源代码文件是属于 AMLL TTML Tool 项目的一部分。
 * This source code file is a part of AMLL TTML Tool project.
 * 本项目的源代码的使用受到 GNU GENERAL PUBLIC LICENSE version 3 许可证的约束，具体可以参阅以下链接。
 * Use of this source code is governed by the GNU GPLv3 license that can be found through the following link.
 *
 * https://github.com/amll-dev/amll-ttml-tool/blob/main/LICENSE
 */

// Cascade: whether the editor can run on this page (secure, isolated), and why not.
import { cannotRun } from "./cascade/secure";
import { enableMapSet } from "immer";
import { Provider } from "jotai";
// import { DevTools } from "jotai-devtools";
// import "jotai-devtools/styles.css";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "react-toastify/dist/ReactToastify.css";
import App from "./App.tsx";
import "./i18n/index.ts";
import "./index.css";
// Cascade: its look, and no offline service worker (utils/pwa.tsx), which on a
// Jellyfin server's address could get in the way of Jellyfin's own web app.
import "./cascade/cascade.css";
import { globalStore } from "./states/store.ts";

async function startApp() {
	enableMapSet();

	// Cascade: no Sentry, Vercel Analytics or Speed Insights. The page is served
	// from a person's own Jellyfin server and reports to no one.
	const rootEl = document.getElementById("root");

	if (!rootEl) {
		throw new Error("Could not find root element");
	}

	const why = cannotRun();
	if (why) {
		rootEl.textContent = why;
		rootEl.setAttribute(
			"style",
			"display:flex;align-items:center;justify-content:center;height:100vh;padding:32px;text-align:center;font:15px/1.5 Inter,system-ui,sans-serif;color:#eef3f8;background:#0a0e13",
		);
		return;
	}

	createRoot(rootEl).render(
		<StrictMode>
			<Provider store={globalStore}>
				<App />
				{/* <DevTools position="bottom-right" /> */}
			</Provider>
		</StrictMode>,
	);
}

startApp();
