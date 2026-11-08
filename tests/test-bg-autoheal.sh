#!/usr/bin/env bash
# dispatch-watch 自癒（11-07 秒回 ④）：bg 單 FAIL → 機械重派一次（prompt 檔名帶 -autoretry-），事件 ACK、不交 Router；
# 重派的那張再 FAIL → 用秘書口吻（brief-answer --kind fail）直接告訴使用者，事件 ACK；STALL → 先 cancel 再重派；
# PASS 直送走 brief-answer --kind done。dispatch-bg／dispatch-cancel／tg-send／brief-answer 全換 stub。
set -eu
export LC_ALL=C  # 跟 launchd 一樣沒有 UTF-8 locale：awk／sed 的方括號會把全形字拆成位元組
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bg-autoheal.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export MYTHOS_DIR="$TMP/mythos" DCQ_HOME="$TMP/dcq" TMUX_BIN="$TMP/tmux" TMUX_LOG="$TMP/tmux.log"
export MYTHOS_TRANSCRIPT_DIR="$TMP/rt" CLAUDE_PROJECTS_DIR="$TMP/projects" CLAUDE_BIN="$TMP/claude" FAKE_AGENTS="$TMP/agents.json"
export DISPATCH_BG_BIN="$TMP/dbg" DISPATCH_CANCEL_BIN="$TMP/dcancel" TG_SEND_BIN="$TMP/tgsend.mjs" BRIEF_BIN="$TMP/brief"
export CALLS="$TMP/calls" BRIEF_LINES_DIR="$TMP/brief-lines"
cat > "$CLAUDE_BIN" <<'S'
#!/bin/sh
case "$1" in agents) tr -d '\n' < "$FAKE_AGENTS"; printf '\n' ;; esac
exit 0
S
printf '#!/bin/sh\necho "dbg $*" >> "$CALLS"\n' > "$DISPATCH_BG_BIN"
# cancel stub 跟真的一樣把帳本改成 cancelled（不然下一輪會被當「worker 不見」再自癒一次）
cat > "$DISPATCH_CANCEL_BIN" <<'S'
#!/bin/sh
echo "cancel $*" >> "$CALLS"
f="$MYTHOS_DIR/state/dispatch-jobs.tsv"; awk -F'\t' -v i="$1" 'BEGIN{OFS="\t"} $1==i{$5="cancelled"} {print}' "$f" > "$f.t" && mv "$f.t" "$f"
S
printf '#!/bin/sh\nprintf "brief %%s\\n" "$*" >> "$CALLS"; sed "s/^/秘書：/"\n' > "$BRIEF_BIN"
printf 'import fs from "node:fs"\nfs.appendFileSync(process.env.CALLS, "tg " + process.argv.slice(2).join(" ") + " :: " + fs.readFileSync(0, "utf8").replace(/\\n/g, " ") + "\\n"); process.exit(Number(process.env.TG_RC || 0))\n' > "$TG_SEND_BIN"
printf '#!/bin/sh\ncase " $* " in *" capture-pane "*) echo idle ;; esac\nprintf "%%s\\n" "$*" >> "$TMUX_LOG"\n' > "$TMUX_BIN"
chmod +x "$CLAUDE_BIN" "$DISPATCH_BG_BIN" "$DISPATCH_CANCEL_BIN" "$BRIEF_BIN" "$TMUX_BIN"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"
mkdir -p "$MYTHOS_DIR/state/bg" "$MYTHOS_TRANSCRIPT_DIR" "$CLAUDE_PROJECTS_DIR"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$MYTHOS_TRANSCRIPT_DIR/router.jsonl"
TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
fail() { echo "FAIL: $*" >&2; exit 1; }
row() { printf '%s\tmid\t%s\t%s\tpending\t%s\t%s\t%s\n' "$1" "$2" "${4:-$(date +%s)}" "$TMP/w" "$3" "${5:-bg}" >> "$TSV"; }
agents() { printf '[{"sessionId":"%s-1111-2222-3333-444455556666","kind":"background","state":"%s","pid":12345}]' "$1" "$2" > "$FAKE_AGENTS"; }
ev() { jq -r --arg e "$1" "select(.event_id==\$e) | $2" "$MYTHOS_DIR/state/events.jsonl"; }
watch() { : > "$CALLS"; : > "$TMUX_LOG"; bash "$ROOT/bin/dispatch-watch" 9>&- || fail "dispatch-watch 非零退出"; }
P="$MYTHOS_DIR/state/bg/t-log-1.md"
printf 'thread：t-log。\n\n> 幫我把 log 輪替修好\n' > "$P"

# 1) FAIL → 重派一次，prompt 帶原任務、檔名 -autoretry-，事件 ACK＋direct=retried，不投遞 Router
row bg-aaaa0001 "$P" t-log; agents aaaa0001 failed
watch
grep -q '^dbg t-log .*/state/bg/t-log-autoretry-[0-9]*-aaaa0001\.md$' "$CALLS" || fail "1：沒重派：$(cat "$CALLS")"
rp="$(sed -n 's/^dbg t-log //p' "$CALLS")"
grep -q '幫我把 log 輪替修好' "$rp" || fail '1：重派 prompt 沒帶原任務'
[ "$(ev bg-aaaa0001-FAIL .direct)" = retried ] || fail "1：direct 應 retried：$(ev bg-aaaa0001-FAIL .direct)"
[ "$(ev bg-aaaa0001-FAIL .acked_at)" != null ] || fail '1：事件沒 ACK'
grep -q 'event_id=bg-aaaa0001-FAIL' "$TMUX_LOG" && fail '1：已重派還投遞給 Router'
grep -q '^tg ' "$CALLS" && fail '1：第一次失敗不該打擾使用者'
echo '(1) ok'

# 2) 重派的那張又 FAIL → 秘書口吻直接告訴使用者（brief --kind fail，q＝原話），不再重派
row bg-bbbb0002 "$rp" t-log; agents bbbb0002 failed
watch
grep -q '^dbg ' "$CALLS" && fail "2：第二次失敗不該再重派：$(cat "$CALLS")"
grep -q '^brief --stdout --kind fail --q 幫我把 log 輪替修好' "$CALLS" || fail "2：沒走 brief fail：$(cat "$CALLS")"
grep -q '^tg --thread t-log --job bg-bbbb0002 :: 秘書：這件事做到一半停了' "$CALLS" || fail "2：沒告知使用者：$(cat "$CALLS")"
[ "$(ev bg-bbbb0002-FAIL .direct)" = sent ] || fail '2：direct 應 sent'
echo '(2) ok'

# 3) STALL → 先 cancel 再重派
row bg-cccc0003 "$P" t-st "$(( $(date +%s) - 7200 ))"; agents cccc0003 working
watch
grep -q '^cancel bg-cccc0003$' "$CALLS" || fail "3：STALL 沒先 cancel：$(cat "$CALLS")"
grep -q '^dbg t-st .*t-st-autoretry-' "$CALLS" || fail '3：STALL 沒重派'
echo '(3) ok'

# 4) bg-hard 不自癒（要 worktree），照舊交 Router
row bg-dddd0004 "$P" t-h "" bg-hard; agents dddd0004 failed
watch
grep -q '^dbg ' "$CALLS" && fail '4：bg-hard 不該自動重派'
[ "$(ev bg-dddd0004-FAIL .direct)" = null ] || fail '4：bg-hard 事件不該被自癒 ACK'
echo '(4) ok'

# 5) PASS 直送走 brief --kind done，不帶代號標題
row bg-eeee0005 "$P" t-ok; agents eeee0005 done
printf 'thread=t-ok\n摘要：\n輪替修好了 commit abc1234\n---細節---\nrc=0\n' > "$MYTHOS_DIR/state/bg/eeee0005.result"
watch
grep -q '^brief --stdout --kind done --q 幫我把 log 輪替修好' "$CALLS" || fail "5：PASS 沒走 brief done：$(cat "$CALLS")"
grep -q '^tg --thread t-ok --job bg-eeee0005 :: 秘書：輪替修好了' "$CALLS" || fail "5：直送內容不對：$(cat "$CALLS")"
echo '(5) ok'

# 6) 重派的那張又 FAIL，告知時 tg-send 回 2（不明，可能已送）→ 當已處理，不交 Router（不重複告知）
printf '> 幫我查 dns\n' > "$MYTHOS_DIR/state/bg/t-dns-autoretry-1.md"
row bg-ffff0006 "$MYTHOS_DIR/state/bg/t-dns-autoretry-1.md" t-dns; agents ffff0006 failed
TG_RC=2 watch
grep -q '^tg --thread t-dns --job bg-ffff0006' "$CALLS" || fail "6：沒試告知：$(cat "$CALLS")"
[ "$(ev bg-ffff0006-FAIL .direct)" = unknown ] || fail "6：direct 應 unknown：$(ev bg-ffff0006-FAIL .direct)"
grep -q 'event_id=bg-ffff0006-FAIL' "$TMUX_LOG" && fail '6：狀態不明還交 Router（會重複告知）'
echo '(6) ok'
echo 'BG-AUTOHEAL PASS'
