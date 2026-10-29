#!/usr/bin/env bats
# Fail-closed contract for the Linux Notetaker mic-only guard.
setup() {
	PATCH_DIR="$BATS_TEST_DIRNAME/../scripts/patches"
	FIX="$BATS_TEST_TMPDIR/hub.js"
}

@test "notetaker-mic-only: guards startMeetingSystemCapture on Linux" {
	cat > "$FIX" <<'JS'
class U{static async startMeetingSystemCapture(e){const t=this.run(e);return t}}
JS
	run bash "$PATCH_DIR/linux-notetaker-mic-only.sh" "$FIX"
	[[ $status -eq 0 ]]
	grep -qF 'WISPR_LINUX_NOTETAKER_MIC_ONLY' "$FIX"
	grep -qF 'static async startMeetingSystemCapture(e){if("linux"===process.platform)return;' "$FIX"
	node --check "$FIX"
}

@test "notetaker-mic-only: is byte-identical on a second application" {
	cat > "$FIX" <<'JS'
class U{static async startMeetingSystemCapture(e){return e}}
JS
	bash "$PATCH_DIR/linux-notetaker-mic-only.sh" "$FIX"
	cp "$FIX" "$FIX.before"
	bash "$PATCH_DIR/linux-notetaker-mic-only.sh" "$FIX"
	cmp "$FIX.before" "$FIX"
}

@test "notetaker-mic-only: refuses a bundle without the method" {
	printf 'const hub = "unrelated";\n' > "$FIX"
	cp "$FIX" "$FIX.before"
	run bash "$PATCH_DIR/linux-notetaker-mic-only.sh" "$FIX"
	[[ $status -ne 0 ]]
	cmp "$FIX.before" "$FIX"
}
