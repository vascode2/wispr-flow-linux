/*WISPR_LINUX_STATUS_NOTIFICATION_SIZE*/
// Injected at the top of .webpack/main/index.js by
// linux-status-notification-size.sh.
//
// The Status window is 200x110 on Linux (linux-status-compact.sh), but a
// status notification card is 400x154 and is rendered inside that window, so
// the card is clipped. This shim grows the window while a notification is
// shown and restores the resting bounds on clear. It does not change the
// compact pill or the window's input handling.
//
// It wraps the Status window's webContents.send, so it sees the same
// notification:show / notification:clear messages main already sends to the
// renderer. Nothing else is intercepted.
;(function () {
	if (process.platform !== "linux") return;
	const {app} = require("electron");
	const SHOW = "notification:show";
	const CLEAR = "notification:clear";
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
		const state = {resting: null, active: false};
		states.set(win, state);
		const send = win.webContents.send.bind(win.webContents);
		win.webContents.send = function (channel, ...args) {
			if (channel === SHOW) {
				if (!state.active) {
					state.resting = win.getBounds();
					state.active = true;
				}
				grow(win, state, sizeFor(args));
			}
			const result = send(channel, ...args);
			if (channel === CLEAR && state.active) {
				state.active = false;
				restore(win, state);
			}
			return result;
		};
	}

	app.on("browser-window-created", (_event, win) => attach(win));
})();
