#!/usr/bin/env bash
# WO3g-r2 驗收：hard 先由 bin/hard-head 用 dc 跑 go flash 兩隻（deepseek→glm），全失敗由 dispatch-watch 靜默交 O 預設鏈。
# 假 dc 記 -m 與 rc、假 dcq 記 env、假 tg-send 記呼叫；不真的派 dcq、不真的跑 dc。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hard-head-test.XXXXXX")"
trap '{ [ -n "${KEEP:-}" ] || rm -rf "$TMP"; }' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

export MYTHOS_DIR="$TMP/mythos"
export DCQ_HOME="$TMP/dcqhome"
export CLAUDE_PROJECTS_DIR="$TMP/projects"
export MYTHOS_TRANSCRIPT_DIR="$TMP/router"
export TMUX_BIN="$TMP/tmux"
ln -s /bin/echo "$TMUX_BIN"  # 永遠回 idle 一行
export DCQ_BIN="$TMP/dcq"
export HARD_HEAD_DC_BIN="$TMP/dc"
export DC_FAIL="$TMP/dc.fail"     # 這些模型要 fail（空白分隔）
export DC_LOG="$TMP/dc.log"
export DCQ_LOG="$TMP/dcq.log"
export TG_LOG="$TMP/tg.log"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"  # F1：自己的 stub 設好之後才 source

cat > "$TMP/dc" <<'STUB'
#!/bin/sh
printf "%s\n" "$*" >> "$DC_LOG"
set +u; prev=""; m=""; for a in "$@"; do [ "$prev" = -m ] && { m="$a"; break; }; prev="$a"; done
f="$(cat "$DC_FAIL" 2>/dev/null)"
mkdir -p "$2/.dc-touched"; : > "$2/.dc-touched/out"  # 假改動，驗 stash（先做才 fail，才驗得到失敗前的半成品）
case " $f " in *" $m "*) exit 1 ;; esac
exit 0
STUB
cat > "$DCQ_BIN" <<'STUB'
#!/bin/sh
if [ "$1" = add ]; then printf '%s\n' "DCQ_ORDER=${DCQ_ORDER:-unset} DCQ_MODELS=${DCQ_MODELS:-unset} tier=$4" >> "$DCQ_LOG"; echo "job-$$"; fi
exit 0
STUB
cat > "$TMP/tg-send" <<'STUB'
#!/bin/sh
cat >/dev/null
echo x >> "$TG_LOG"
STUB
chmod +x "$TMP/dc" "$DCQ_BIN" "$TMP/tg-send"
export TG_SEND_BIN="$TMP/tg-send"
mkdir -p "$MYTHOS_DIR/state/deep" "$DCQ_HOME/done" "$DCQ_HOME/failed" "$DCQ_HOME/running" "$DCQ_HOME/pending" \
  "$CLAUDE_PROJECTS_DIR" "$MYTHOS_TRANSCRIPT_DIR"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$MYTHOS_TRANSCRIPT_DIR/router.jsonl"

TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
CO="$MYTHOS_DIR/state/closeouts.tsv"
: > "$DC_LOG"; : > "$DCQ_LOG"; : > "$TG_LOG"; : > "$DC_FAIL"

# head 分支固定走真 dispatch-deep-run（它再起 hard-head）。dispatch 的守門因 DEEP_RUN_BIN 指回 repo 的 hard-head 而拒跑，
# 且 runner 用 nohup 起、拿不到它算出的 id；所以這裡跳過 dispatch 的 deep 分支，自己起真 dispatch-deep-run
# （sandbox 內同名副本，守門看到 BINH 指回 sandbox 內的 hard-head 副本）＋ 寫同格式 ledger 列。
H="$TMP/harness"; mkdir -p "$H/bin"
export BINH="$H/bin/hard-head"
cp "$ROOT/bin/hard-head" "$BINH"

reset() { : > "$DC_LOG"; : > "$DCQ_LOG"; : > "$TG_LOG"; : > "$DC_FAIL"; : > "$TSV"; rm -rf "$MYTHOS_DIR/state/deep" "$CO"; mkdir -p "$MYTHOS_DIR/state/deep"; }
models() { sed -n 's/.*-- -m //p' "$DC_LOG"; }
dispatch_deep() { # 規格 2：同樣的列格式／runner／DEEP_RUN_BIN / billing-quiet
  local tier="$1" task="$2" cwd="$3" id
  id="deep-$(date +%s)-$$-$(basename "$task" .md)"
  grep -qx '<!-- dc:billing-quiet -->' "$task" || printf '\n<!-- dc:billing-quiet -->\n' >> "$task"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$tier" "$task" "$(date +%s)" pending "$cwd" - head >> "$TSV"
  DEEP_RUN_BIN="$BINH" "$DDR" "$id" "$task" "$cwd" >/dev/null 2>&1 9>&- &
  printf '%s\n' "$id"
}
dispatch() { local t="${3:-hard}"; [ "$t" = hard ] && { dispatch_deep hard "$1" "$2"; return; }
  DISPATCH_THREAD= bash "$ROOT/bin/dispatch" "$1" "$2" "$t" >/dev/null; }
DDR="$H/bin/dispatch-deep-run"
cp "$ROOT/bin/dispatch-deep-run" "$ROOT/bin/lib-ledger.sh" "$H/bin/"
# 等 deep 背景鏈跑完（runner → hard-head → 假 dc）
wait_rc() { local n=0; while [ ! -s "$MYTHOS_DIR/state/deep/$1.rc" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n+1)); done; }
watch() { bash "$ROOT/bin/dispatch-watch" 9>&- >/dev/null 2>&1 || fail 'dispatch-watch 非零退出'; }

git init -q "$TMP/repo"
git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init  # unborn repo 不能 stash
: > "$TMP/t.md"; printf "# t\n" > "$TMP/t.md"

# (a) hard 預設 → 後端 head，第一隻假失敗 → dc 依序收 deepseek、glm
reset
printf 'opencode-go/deepseek-v4.1-flash\n' > "$DC_FAIL"
id="$(dispatch "$TMP/t.md" "$TMP/repo")"
[ "$(awk -F'\t' -v i="$id" '$1==i{print $8}' "$TSV")" = head ] || fail "(a) 後端欄不是 head：$(cat "$TSV")"
grep -qx '<!-- dc:billing-quiet -->' "$TMP/t.md" || fail '(a) head 工單缺 billing-quiet 標記'
wait_rc "$id"
[ "$(cat "$MYTHOS_DIR/state/deep/$id.rc")" = 0 ] || fail "(a) 第一隻失敗、第二隻成功應 rc=0：$(cat "$MYTHOS_DIR/state/deep/$id.out" 2>/dev/null)"
[ "$(models | tr '\n' ' ')" = 'opencode-go/deepseek-v4.1-flash opencode-go/glm-5.3-flash ' ] || fail "(a) dc 模型順序不對：$(models)"
[ "$(git -C "$TMP/repo" stash list | wc -l | tr -d ' ')" = 1 ] || fail '(a) 第一隻失敗後應 stash 半成品'
git -C "$TMP/repo" stash drop -q
[ "$(git -C "$TMP/repo" status --porcelain)" = '?? .dc-touched/' ] || fail "(a) 工作樹應只剩第二隻的改動：$(git -C "$TMP/repo" status --porcelain)"

# (b) 第一隻成功 → 不呼叫第二隻、不 stash
reset
: > "$TMP/t2.md"; printf "# t\n" > "$TMP/t2.md"
id="$(dispatch "$TMP/t2.md" "$TMP/repo")"
wait_rc "$id"
[ "$(models)" = 'opencode-go/deepseek-v4.1-flash' ] || fail "(b) 第一隻成功就不該再跑：$(models)"
[ "$(git -C "$TMP/repo" stash list | wc -l | tr -d ' ')" = 0 ] || fail '(b) 成功不該 stash'

# (c) 兩隻都失敗 → watch 靜默重派：dcq 一次（default、無 DCQ_MODELS）、tg-send 不叫、舊列 closeouts=retried
reset
rm -rf "$TMP/repo/.dc-touched"
printf 'opencode-go/deepseek-v4.1-flash opencode-go/glm-5.3-flash\n' > "$DC_FAIL"
: > "$TMP/t3.md"; printf "# t\n" > "$TMP/t3.md"
id="$(dispatch "$TMP/t3.md" "$TMP/repo")"
wait_rc "$id"
[ "$(cat "$MYTHOS_DIR/state/deep/$id.rc")" = 1 ] || fail '(c) 兩隻都失敗應 rc=1'
watch
[ "$(grep -c . "$DCQ_LOG")" = 1 ] || fail "(c) 假 dcq 應被呼叫一次：$(cat "$DCQ_LOG")"
grep -qx 'DCQ_ORDER=default DCQ_MODELS=unset tier=hard' "$DCQ_LOG" || fail "(c) dcq 應收 default 且無 DCQ_MODELS：$(cat "$DCQ_LOG")"
[ "$(awk -F'\t' -v i="$id" '$1==i{print $3}' "$CO" 2>/dev/null)" = retried ] || fail "(c) 舊列 closeouts 應是 retried：$(cat "$CO" 2>/dev/null)"
if [ -s "$MYTHOS_DIR/state/events.jsonl" ] && jq -e --arg i "$id" 'select(.job_id==$i)' "$MYTHOS_DIR/state/events.jsonl" >/dev/null 2>&1; then
  fail '(c) 舊列不該產生任何事件'
fi
# 重派後第一隻成功（新票），watch 再跑一輪 → PASS 事件走 Router，不直發 TG
: > "$DC_FAIL"
watch
[ -s "$TG_LOG" ] && fail "(c) 假 tg-send 不該被呼叫：$(cat "$TG_LOG")"

# (d) DISPATCH_HARD_HEAD= → 直接 dcq，不叫 dc
reset
: > "$TMP/t4.md"; printf "# t\n" > "$TMP/t4.md"
DISPATCH_HARD_HEAD= DISPATCH_THREAD= bash "$ROOT/bin/dispatch" "$TMP/t4.md" "$TMP/repo" hard >/dev/null
grep -q 'DCQ_ORDER=default DCQ_MODELS=unset tier=hard' "$DCQ_LOG" || fail "(d) 應直接走 dcq default：$(cat "$DCQ_LOG")"
[ -s "$DC_LOG" ] && fail "(d) 不該叫 dc：$(cat "$DC_LOG")"

# (e) mid 不叫 dc
reset
: > "$TMP/t5.md"; printf "# t\n" > "$TMP/t5.md"
dispatch "$TMP/t5.md" "$TMP/repo" mid
[ -s "$DC_LOG" ] && fail "(e) mid 不該叫 dc：$(cat "$DC_LOG")"
grep -q 'DCQ_ORDER=default DCQ_MODELS=unset tier=mid' "$DCQ_LOG" || fail "(e) mid 應走 dcq default"

# (f) hard-head：sandbox 外的 dc → exit 97
set +e
MYTHOS_TEST_SANDBOX="$TMP" HARD_HEAD_DC_BIN=~/.local/bin/dc bash "$ROOT/bin/hard-head" "$TMP/t.md" "$TMP/repo" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 97 ] || fail "(f) sandbox 外 dc 應 exit 97，得到 $rc"

echo "DISPATCH-HARD-HEAD PASS"
