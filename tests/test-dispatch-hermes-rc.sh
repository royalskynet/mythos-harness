#!/usr/bin/env bash
# 11-08b dsh 差距 #1：hermes worker 完成判定。
# (a) dispatch-bg：stdout 只進 result、stderr 進 <result>.err、結束碼進 <result>.rc
# (b) dispatch-watch：rc≠0 → FAIL；rc=0 但 stdout 去空白為空 → FAIL；rc=0 且有內容 → PASS；沒有 rc 檔的舊列照現狀（result 有內容＝PASS）
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hermes-rc.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export MYTHOS_DIR="$TMP/mythos" MYTHOS_WORKER_DIR="$TMP/worker" DCQ_HOME="$TMP/dcq"
export ROUTER_SLUG="dshgap-rc-$$"
export DISPATCH_BG_HERMES_BIN="$TMP/hermes" CLAUDE_BIN="$TMP/claude"
export FAKE_AGENTS="$TMP/agents.json" FAKE_ID="$TMP/fake-id"
mkdir -p "$MYTHOS_DIR/state/bg" "$MYTHOS_WORKER_DIR" "$DCQ_HOME"
echo '[]' > "$FAKE_AGENTS"; echo cafe0003-0000-0000-0000-000000000000 > "$FAKE_ID"
printf '#!/bin/sh\n[ "${1:-}" = agents ] && { cat "$FAKE_AGENTS"; exit 0; }\nexit 0\n' > "$CLAUDE_BIN"
# 假 hermes：stdout 印 OUTLINE、stderr 印 ERRLINE、結束碼 3
cat > "$DISPATCH_BG_HERMES_BIN" <<'STUB'
#!/bin/sh
echo OUTLINE
echo ERRLINE >&2
exit 3
STUB
chmod +x "$CLAUDE_BIN" "$DISPATCH_BG_HERMES_BIN"
echo 'process.stdin.resume(); process.exit(0);' > "$TMP/tgsend.mjs"; export TG_SEND_BIN="$TMP/tgsend.mjs"
printf '#!/bin/sh\nexit 0\n' > "$TMP/tmux"; chmod +x "$TMP/tmux"; export TMUX_BIN="$TMP/tmux"
mkdir -p "$TMP/rt"; printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$TMP/rt/router.jsonl"
export MYTHOS_TRANSCRIPT_DIR="$TMP/rt" CLAUDE_PROJECTS_DIR="$TMP/projects" BG_AUTOHEAL=0
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"
fail() { echo "FAIL: $*" >&2; exit 1; }
TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
printf 'doing x\n' > "$TMP/p.md"

# (a) dispatch-bg 分檔
DISPATCH_BG_WORKER=hermes bash "$ROOT/bin/dispatch-bg" t-rc "$TMP/p.md" >"$TMP/id.out" 2>/dev/null </dev/null
id="$(cat "$TMP/id.out")"; sid="${id#bg-}"
rk="$(tr -d '[:space:]' < "$MYTHOS_DIR/state/bg/$sid.rkey")"
rf="$MYTHOS_DIR/state/bg/r-$rk.result"
for i in $(seq 1 50); do [ -s "$rf.rc" ] && break; sleep 0.1; done
[ "$(tr -d '[:space:]' < "$rf.rc" 2>/dev/null)" = 3 ] || fail "(a) .rc 不是 3：$(cat "$rf.rc" 2>/dev/null)"
grep -q OUTLINE "$rf" && ! grep -q ERRLINE "$rf" || fail "(a) result 應只有 stdout：$(cat "$rf")"
grep -q ERRLINE "$rf.err" || fail "(a) stderr 沒進 .err：$(cat "$rf.err" 2>/dev/null)"
echo '(a) ok'

# 造列：mkrow <id> <thread> <result內容|-> <rc|-> ；結果檔 r-rk-<sid>.result
mkrow() {
  local rid="$1" th="$2" body="$3" rc="$4" s="${1#bg-}"
  printf '%s\n' "rk-$s" > "$MYTHOS_DIR/state/bg/$s.rkey"
  [ "$body" = - ] || printf '%b' "$body" > "$MYTHOS_DIR/state/bg/r-rk-$s.result"
  [ "$rc" = - ] || printf '%s\n' "$rc" > "$MYTHOS_DIR/state/bg/r-rk-$s.result.rc"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rid" mid "$TMP/p.md" "$(( $(date +%s) - 60 ))" pending "$MYTHOS_WORKER_DIR" "$th" hermes >> "$TSV"
}
mkrow bg-aaaa0002 t-b1 '摘要：x\n---細節---\ny\n' 0       # rc=0 有內容 → PASS
mkrow bg-aaaa0003 t-b2 '  \n\n' 0                          # rc=0 stdout 全空白 → FAIL
mkrow bg-aaaa0004 t-b3 '摘要：z\n---細節---\ny\n' 2       # rc=2 → FAIL
mkrow bg-aaaa0005 t-b4 '摘要：legacy\n---細節---\ny\n' -  # 沒 rc 檔的舊列、沒 pid、result 有內容 → PASS（相容）
BG_PERM_MIN=100000 BG_STALL_MIN=100000 RESEND_SEC=100000 bash "$ROOT/bin/dispatch-watch" 9>&- || fail 'watch 非零退出'
ev="$MYTHOS_DIR/state/events.jsonl"
st_of() { jq -rs --arg i "$1" '[.[] | select(.job_id==$i) | .status] | join(",")' "$ev"; }
[ "$(st_of "$id")" = FAIL ] || fail "(b0) dispatch-bg 起的 rc=3 單應 FAIL：$(st_of "$id")"
jq -rs --arg i "$id" '.[] | select(.job_id==$i) | .extra' "$ev" | grep -q '結束碼 3' || fail "(b0) FAIL 原因沒帶結束碼"
jq -rs --arg i "$id" '.[] | select(.job_id==$i) | .extra' "$ev" | grep -q 'ERRLINE' || fail "(b0) FAIL 原因沒帶 stderr"
[ "$(st_of bg-aaaa0002)" = PASS ] || fail "(b1) rc=0 有內容應 PASS：$(st_of bg-aaaa0002)"
[ "$(st_of bg-aaaa0003)" = FAIL ] || fail "(b2) stdout 空白應 FAIL：$(st_of bg-aaaa0003)"
[ "$(st_of bg-aaaa0004)" = FAIL ] || fail "(b3) rc≠0 應 FAIL：$(st_of bg-aaaa0004)"
[ "$(st_of bg-aaaa0005)" = PASS ] || fail "(b4) 舊列（無 rc 檔）應照舊 PASS：$(st_of bg-aaaa0005)"
echo '(b) ok'
echo 'DISPATCH-HERMES-RC PASS'
