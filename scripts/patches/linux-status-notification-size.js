/*WISPR_LINUX_STATUS_NOTIFICATION_SIZE*/
// Injected at the top of .webpack/main/index.js by
// linux-status-notification-size.sh.
//
// The Status window is 200x110 on Linux (linux-status-compact.sh), but a
// status notification card is 400x154 and is rendered inside that window, so
// the card is clipped. This shim grows the window while a notification is
// shown and restores the resting bounds on clear.
//
// The Status window is click-through on Linux, so the pill's own controls
// (the Notetaker stop button) and notification cards receive no clicks. The
// renderer's status:reportAlphaCatchRects report says whether a surface is
// visible; while it is, or while a notification is shown, this shim forces
// the window to accept input and restores click-through when both are gone.
//
// It wraps the Status window's webContents.send and listens to the surface
// report main already receives. Nothing else is intercepted.
;(function () {
	if (process.platform !== "linux") return;
	const {app, BrowserWindow, ipcMain} = require("electron");
	const SHOW = "notification:show";
	const CLEAR = "notification:clear";
	const REPORT = "status:reportAlphaCatchRects";
	const STANDARD = {width: 440, height: 200};
	const SPLASH = {width: 800, height: 420};
	const states = new WeakMap();

	function sizeFor(args) {
		const payload = args[0];
		return payload && (payload.variant === "splash" || payload.heroFit)
			? SPLASH
			: STANDARD;
	}

	function grow(win, state, size) {
		if (win.isDestroyed()) return;
		const b = win.getBounds();
		const width = Math.max(b.width, size.width);
		const height = Math.max(b.height, size.height);
		win.setBounds({
			x: b.x + Math.round((b.width - width) / 2),
			y: b.y + b.height - height,
			width,
			height,
		});
	}

	function restore(win, state) {
		if (win.isDestroyed() || !state.resting) return;
		const b = win.getBounds();
		win.setBounds({
			x: b.x + Math.round((b.width - state.resting.width) / 2),
			y: b.y + b.height - state.resting.height,
			width: state.resting.width,
			height: state.resting.height,
		});
	}

	function attach(win) {
		if (win.getTitle() !== "Flow Status Indicator") return;
		const state = {resting: null, active: false, surface: false};
		states.set(win, state);
		const send = win.webContents.send.bind(win.webContents);
		const setIgnore = win.setIgnoreMouseEvents.bind(win);
		// The Status window is click-through on Linux; while a surface (pill)
		// or a notification is visible the window must accept clicks.
		win.setIgnoreMouseEvents = function (ignore, options) {
			if (state.active || state.surface) ignore = false;
			return setIgnore(ignore, options);
		};
		win.webContents.send = function (channel, ...args) {
			if (channel === SHOW) {
				if (!state.active) {
					state.resting = win.getBounds();
					state.active = true;
				}
				grow(win, state, sizeFor(args));
				win.setIgnoreMouseEvents(false);
			}
			const result = send(channel, ...args);
			if (channel === CLEAR && state.active) {
				state.active = false;
				win.setIgnoreMouseEvents(!state.surface, {forward: true});
				restore(win, state);
			}
			return result;
		};
	}

	ipcMain.on(REPORT, (event, report) => {
		const win = BrowserWindow.fromWebContents(event.sender);
		const state = win && states.get(win);
		if (!state || !report) return;
		const rects = Array.isArray(report.rects) ? report.rects : [];
		const shapes = Array.isArray(report.shapeRects) ? report.shapeRects : [];
		state.surface = rects.length > 0 || shapes.length > 0;
		win.setIgnoreMouseEvents(!state.surface && !state.active, {forward: true});
	});

	app.on("browser-window-created", (_event, win) => attach(win));
})();
