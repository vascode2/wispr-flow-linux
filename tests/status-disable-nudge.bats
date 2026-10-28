#!/usr/bin/env bats
# Fail-closed contract for the Status nudge-pulsar removal.
setup() {
	PATCH_DIR="$BATS_TEST_DIRNAME/../scripts/patches"
	FIX="$BATS_TEST_TMPDIR/status.js"
}

@test "disable-nudge: disables the status-bubble pulsar call" {
	cat > "$FIX" <<'JS'
const a=1;Lt&&(0,j.jsx)(sh,{anchorName:"--status-bubble",size:"small",position:"center"});const b=2;
JS
	run bash "$PATCH_DIR/linux-status-disable-nudge.sh" "$FIX"
	[[ $status -eq 0 ]]
	grep -qF '!1&&(0,j.jsx)(sh,{anchorName:"--status-bubble",size:"small",position:"center"})' "$FIX"
	grep -qF 'WISPR_LINUX_STATUS_DISABLE_NUDGE' "$FIX"
	node --check "$FIX"
}

@test "disable-nudge: is byte-identical on a second application" {
	cat > "$FIX" <<'JS'
Lt&&(0,j.jsx)(sh,{anchorName:"--status-bubble",size:"small",position:"center"});
JS
	bash "$PATCH_DIR/linux-status-disable-nudge.sh" "$FIX"
	cp "$FIX" "$FIX.before"
	bash "$PATCH_DIR/linux-status-disable-nudge.sh" "$FIX"
	cmp "$FIX.before" "$FIX"
}

@test "disable-nudge: refuses a renderer without the pulsar" {
	printf 'const renderer = "unrelated";\n' > "$FIX"
	cp "$FIX" "$FIX.before"
	run bash "$PATCH_DIR/linux-status-disable-nudge.sh" "$FIX"
	[[ $status -ne 0 ]]
	cmp "$FIX.before" "$FIX"
}
