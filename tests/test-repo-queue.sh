#!/usr/bin/env bash
# 同 repo 寫入佇列（C3）驗收：同一個 git repo 同時只能有一張 deep 票在跑，其餘 queued，第一張落地後由 dispatch-watch 拉起。
# 全部用暫存 MYTHOS_DIR／DCQ_HOME／假 tmux／假 runner（DISPATCH_DEEP_RUN_BIN），不碰真的 state、tmux、dcq。
# 假 runner 只記 argv 後 exec sleep 30；背景 pid 登記到 BG_PIDS，EXIT trap 一律清掉。
set -eu
export DISPATCH_HARD_BACKEND=deep  # 工單 D：hard 預設改 bg-hard；本檔驗的是 deep 舊路徑，明設才走 deep-run
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/repo-queue-test.XXXXXX")"
BG_PIDS=()
cleanup() {
  for p in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do
    for k in $(pgrep -P "$p" 2>/dev/null); do kill "$k" 2>/dev/null || true; done
    kill "$p" 2>/dev/null || true
  done
  chflags -R nouchg "$TMP" 2>/dev/null || true  # 8b 中途失敗時 events.jsonl 還帶 uchg，rm 刪不掉
  [ -n "${KEEP:-}" ] || rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# stub 一律放 harness 目錄，不落進會被掃描的 MYTHOS_DIR
H="$TMP/harness"; mkdir -p "$H"
export MYTHOS_DIR="$TMP/mythos"
export DCQ_HOME="$TMP/dcq"
export CLAUDE_PROJECTS_DIR="$TMP/projects"
export MYTHOS_TRANSCRIPT_DIR="$TMP/router"
export TMUX_BIN="$H/tmux"
export DISPATCH_DEEP_RUN_BIN="$H/stub-runner"
export STUB_LOG="$H/stub.log"
export STUB_PIDS="$H/stub.pids"
export REVIEW_JUDGE="$H/no-judge"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"  # F1：自己的 stub 設好之後才 source；沒設的 runner／tmux 換 guard stub
mkdir -p "$MYTHOS_DIR/state/deep" "$DCQ_HOME/done" "$DCQ_HOME/failed" "$DCQ_HOME/running" "$DCQ_HOME/pending" \
  "$CLAUDE_PROJECTS_DIR" "$MYTHOS_TRANSCRIPT_DIR"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$MYTHOS_TRANSCRIPT_DIR/router.jsonl"
printf '#!/bin/sh\necho idle\nexit 0\n' > "$TMUX_BIN"; chmod +x "$TMUX_BIN"
cat > "$DISPATCH_DEEP_RUN_BIN" <<'STUB'
#!/bin/sh
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STUB_LOG"
echo "$$" >> "$STUB_PIDS"
exec sleep 30
STUB
chmod +x "$DISPATCH_DEEP_RUN_BIN"
: > "$STUB_LOG"; : > "$STUB_PIDS"

TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
ERR="$H/err"
status_of() { awk -F'\t' -v id="$1" '$1 == id { print $5; exit }' "$TSV"; }
started() { awk -F'\t' -v id="$1" '$1 == id' "$STUB_LOG" | wc -l | tr -d ' '; }
runners() { grep -c . "$STUB_PIDS" 2>/dev/null | tr -d ' '; }
dispatch() { DISPATCH_THREAD= bash "$ROOT/bin/dispatch" "$1" "$2" hard 2>"$ERR"; }
watch() { bash "$ROOT/bin/dispatch-watch" 9>&- || fail 'dispatch-watch 非零退出'; }
# 把 pid 檔裡全部的 runner 記進 cleanup
track() { while IFS= read -r p; do [ -n "$p" ] && BG_PIDS+=("$p"); done < "$STUB_PIDS"; }

for r in A B; do mkdir -p "$TMP/repo$r/sub"; git -C "$TMP/repo$r" init -q; done
: > "$TMP/tA.md"; : > "$TMP/tA2.md"; : > "$TMP/tB.md"; : > "$TMP/tB2.md"

# 1) 同一 repo 兩張（一個給子目錄）→ 第一張 pending 並啟動、第二張 queued 不啟動
id1="$(dispatch "$TMP/tA.md" "$TMP/repoA/sub")"
id2="$(dispatch "$TMP/tA2.md" "$TMP/repoA")"
track
[ "$(status_of "$id1")" = pending ] || fail "1：第一張不是 pending：$(status_of "$id1")"
[ "$(status_of "$id2")" = queued ] || fail "1：第二張不是 queued：$(status_of "$id2")"
grep -qF "已排隊：${id1}" "$ERR" || fail "1：排隊訊息沒帶第一張 id：$(cat "$ERR")"
[ "$(started "$id1")" = 1 ] || fail '1：第一張沒啟動 runner'
[ "$(started "$id2")" = 0 ] || fail '1：queued 那張被啟動了 runner'
[ "$(runners)" = 1 ] || fail "1：runner 數不是 1：$(runners)"

# 2) 第一張寫 rc=0 → 跑一輪 dispatch-watch → 第二張 pending、runner 啟動
printf '0\n' > "$MYTHOS_DIR/state/deep/$id1.rc"
watch
track
[ "$(status_of "$id2")" = pending ] || fail "2：第一張落地後第二張沒變 pending：$(status_of "$id2")"
[ "$(started "$id2")" = 1 ] || fail '2：第二張沒被拉起 runner'
[ "$(runners)" = 2 ] || fail "2：runner 數不是 2：$(runners)"
# 拉起只改那一列：其餘列狀態不動、整檔仍是 8 欄 tab 分隔（曾因 awk 沒設 OFS／s[$1] 副作用整檔變空白分隔、全改 pending）
[ "$(status_of "$id1")" = pending ] || fail "2：沒被拉起的列狀態被改：$(status_of "$id1")"
awk -F'\t' 'NF != 8 { bad=1 } END { exit bad }' "$TSV" || fail "2：ledger 不再是 8 欄 tab 分隔：$(sed -n l "$TSV")"

# 3) 不同 repo → 不排隊；同 repo 子目錄 → 排隊
id3="$(dispatch "$TMP/tB.md" "$TMP/repoB")"
[ "$(status_of "$id3")" = pending ] || fail "3：不同 repo 也被排隊：$(status_of "$id3")"
id4="$(dispatch "$TMP/tB2.md" "$TMP/repoA/sub")"
[ "$(status_of "$id4")" = queued ] || fail "3：同 repo 子目錄沒排隊：$(status_of "$id4")"
track
# 同 top 還有 pending 未落地（id2）→ 這輪不拉起 id4
watch
[ "$(status_of "$id4")" = queued ] || fail "3：同 repo 還有票在跑卻被拉起：$(status_of "$id4")"
[ "$(started "$id4")" = 0 ] || fail '3：同 repo 還有票在跑卻啟動了 runner'

# 4) cancel queued → cancelled、exit 0（沒有 handle），之後 queue 也不會拉起它
bash "$ROOT/bin/dispatch-cancel" "$id4" 2>/dev/null || fail '4：cancel queued 非零退出'
[ "$(status_of "$id4")" = cancelled ] || fail "4：cancel queued 後不是 cancelled：$(status_of "$id4")"
watch
track
[ "$(started "$id4")" = 0 ] || fail '4：cancelled 的票被 queue 拉起'

# 5) queued 逾 6 小時：watchdog 不把它算進 pending 逾時
id5="$(dispatch "$TMP/tA.md" "$TMP/repoA")"
[ "$(status_of "$id5")" = queued ] || fail "5：預期 queued：$(status_of "$id5")"
old=$(( $(date +%s) - 30000 ))
awk -v id="$id5" -v t="$old" -F'\t' 'BEGIN{OFS="\t"} $1==id { $4=t } { print }' "$TSV" > "$TSV.k" && mv "$TSV.k" "$TSV"
track
# watchdog 的外部依賴一律換成假的（不叫 claude、不叫模型、不打 scrub），只看 L0 第 4 步
printf '#!/bin/sh\nexit 0\n' > "$H/true"; chmod +x "$H/true"
printf '#!/bin/sh\nexit 1\n' > "$H/false"; chmod +x "$H/false"
MYTHOS_BRIEF_DIR="$H/brief" WATCHDOG_CLAUDE_BIN="$H/true" WATCHDOG_LLM_LEGS="$H/false" WATCHDOG_SCRUB_CMD="$H/false" \
  WATCHDOG_CANARY_CMD="$H/true" WATCHDOG_LLM_TIMEOUT_S=3 bash "$ROOT/bin/watchdog" >/dev/null 2>&1 || true
BRIEF="$H/brief/mythos-watchdog.tsv"
[ -f "$BRIEF" ] || fail '5：watchdog 沒寫出告警檔'
grep -qF "派工 $id5 queued 逾 6 小時" "$BRIEF" || fail "5：queued 逾 6 小時沒另計告警：$(cat "$BRIEF")"
grep -F "$id5" "$BRIEF" | grep -q '卡在 pending' && fail '5：queued 被當成 pending 逾時告警'

# ---------- 以下每段換一個乾淨的 MYTHOS_DIR，ledger 內容完全由本段決定 ----------
section() { # 名稱 → 換 MYTHOS_DIR／TSV，清 stub 紀錄
  export MYTHOS_DIR="$TMP/$1/mythos"
  TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
  mkdir -p "$MYTHOS_DIR/state/deep"
}
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" hard "$TMP/$1.md" "$2" "$3" "$4" - deep >> "$TSV"; }
epoch_of() { awk -F'\t' -v id="$1" '$1 == id { print $4; exit }' "$TSV"; }
for r in C D E F G; do mkdir -p "$TMP/repo$r"; git -C "$TMP/repo$r" init -q; done
NOW="$(date +%s)"

# 6) F8：一次真升級，非目標列原文不變。升級前放 cancelled、notified-PASS、本輪排不進去的 queued、dcq 列。
section f8
row c-done $((NOW - 50)) pending "$TMP/repoC"; printf '0\n' > "$MYTHOS_DIR/state/deep/c-done.rc"
row c-target $((NOW - 40)) queued "$TMP/repoC"
row c-cxl $((NOW - 30)) cancelled "$TMP/repoC"
row c-noti $((NOW - 30)) notified-PASS "$TMP/repoC"
row d-run $((NOW - 20)) pending "$TMP/repoD"; printf 'fixture=1\n' > "$MYTHOS_DIR/state/deep/d-run.handle"
row d-wait $((NOW - 10)) queued "$TMP/repoD"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' o-1 mid "$TMP/o.md" "$NOW" pending "$TMP" - dcq >> "$TSV"
cp -R "$MYTHOS_DIR" "$TMP/f8/snapshot"
before="$TMP/f8/before.tsv"; cp "$TSV" "$before"
nontarget() { # $1 ledger → 印出 before 裡非目標列中，在 $1 找不到原文的列
  grep -v '^c-target	' "$before" | while IFS= read -r line; do grep -qxF -- "$line" "$1" || printf '%s\n' "$line"; done
}
: > "$STUB_LOG"
watch
track
[ "$(status_of c-target)" = pending ] || fail "6：c-target 沒被升級：$(status_of c-target)"
[ "$(started c-target)" = 1 ] || fail '6：c-target 沒被拉起 runner'
[ "$(status_of d-wait)" = queued ] || fail "6：被 d-run 擋住的 d-wait 被升級了：$(status_of d-wait)"
m="$(nontarget "$TSV")"
[ -z "$m" ] || fail "6：升級時改到了非目標列：$(printf '%s\n' "$m" | sed -n l)"
awk -F'\t' 'NF != 8 { bad=1 } END { exit bad }' "$TSV" || fail "6：ledger 不再是 8 欄 tab 分隔：$(sed -n l "$TSV")"
# 突變：dispatch-watch 的 promote_rows 改成「每列都設 pending」，同一份 ledger 真跑一輪，逐列比對必須抓到
MUT="$H/mut"; mkdir -p "$MUT"
ln -sf "$ROOT/bin/lib-ledger.sh" "$MUT/lib-ledger.sh"; ln -sf "$ROOT/bin/lib-events.mjs" "$MUT/lib-events.mjs"
[ "$(grep -cx '# end promote_rows' "$ROOT/bin/dispatch-watch")" = 1 ] || fail '6：dispatch-watch 找不到 promote_rows 結尾標記，突變做不了'
awk '{ print } $0 == "# end promote_rows" {
  print "promote_rows() { awk -F\"\\t\" -v now=\"$3\" '"'"'BEGIN { OFS=\"\\t\" } NR==FNR { next } { NF=8; $5=\"pending\"; $4=now } { print }'"'"' \"$1\" \"$2\"; }"
}' "$ROOT/bin/dispatch-watch" > "$MUT/dispatch-watch"
cmp -s "$ROOT/bin/dispatch-watch" "$MUT/dispatch-watch" && fail '6：突變沒生效'
rm -rf "$MYTHOS_DIR"; cp -R "$TMP/f8/snapshot" "$MYTHOS_DIR"
bash "$MUT/dispatch-watch" 9>&- || true
track
[ "$(status_of c-cxl)" = pending ] || fail "6：突變版沒把 cancelled 改成 pending，突變本身沒生效：$(status_of c-cxl)"
m="$(nontarget "$TSV")"
[ -n "$m" ] || fail '6：突變版（無條件全部 pending）也通過逐列比對，測試抓不到'

# 7) F4：A 已寫 rc、B queued，watcher 還沒跑時派 C → C 也 queued；跑 watcher → 先拉起 B
section f4
: > "$TMP/tE-a.md"; : > "$TMP/tE-b.md"; : > "$TMP/tE-c.md"
: > "$STUB_LOG"
ida="$(dispatch "$TMP/tE-a.md" "$TMP/repoE")"
idb="$(dispatch "$TMP/tE-b.md" "$TMP/repoE")"
track
[ "$(status_of "$idb")" = queued ] || fail "7：B 不是 queued：$(status_of "$idb")"
printf '0\n' > "$MYTHOS_DIR/state/deep/$ida.rc"
idc="$(dispatch "$TMP/tE-c.md" "$TMP/repoE")"
track
[ "$(status_of "$idc")" = queued ] || fail "7：A 落地、B 還在排，C 卻插隊：$(status_of "$idc")"
[ "$(started "$idc")" = 0 ] || fail '7：插隊的 C 啟動了 runner'
watch
track
[ "$(status_of "$idb")" = pending ] || fail "7：watcher 沒先拉起 B：$(status_of "$idb")"
[ "$(started "$idb")" = 1 ] || fail '7：B 沒啟動 runner'
[ "$(status_of "$idc")" = queued ] || fail "7：C 跟 B 同輪被拉起：$(status_of "$idc")"
[ "$(started "$idc")" = 0 ] || fail '7：C 跟 B 同輪啟動了 runner'

# 8) F2：runner 直接 exit 1、不寫 handle → 未逾 DEEP_HANDOFF_SEC 不動；逾時一輪只寫 handoff＋rc=127，
#    ledger 不改、由第 1 步出 FAIL（extra 帶原因），同 repo 的 queued 同一輪被拉起。寫不了（事件寫入失敗）下輪可重掃。
section f3
printf '#!/bin/sh\nexit 1\n' > "$H/dead-runner"; chmod +x "$H/dead-runner"
: > "$TMP/tF-a.md"; : > "$TMP/tF-b.md"
: > "$STUB_LOG"
ida="$(DISPATCH_DEEP_RUN_BIN="$H/dead-runner" dispatch "$TMP/tF-a.md" "$TMP/repoF")"
idb="$(dispatch "$TMP/tF-b.md" "$TMP/repoF")"
[ "$(status_of "$ida")" = pending ] || fail "8：A 不是 pending：$(status_of "$ida")"
[ "$(status_of "$idb")" = queued ] || fail "8：B 不是 queued：$(status_of "$idb")"
watch
[ "$(status_of "$ida")" = pending ] || fail "8：還沒逾 DEEP_HANDOFF_SEC 就被收成：$(status_of "$ida")"
old=$(( $(date +%s) - 121 ))
awk -v id="$ida" -v t="$old" -F'\t' 'BEGIN{OFS="\t"} $1==id { $4=t } { print }' "$TSV" > "$TSV.k" && mv "$TSV.k" "$TSV"
watch
track
[ "$(tr -d '[:space:]' < "$MYTHOS_DIR/state/deep/$ida.rc")" = 127 ] || fail '8：rc 不是 127'
# F4：未 ACK 時該列精確仍是 pending（不准被改成 failed）
[ "$(status_of "$ida")" = pending ] || fail "8：未 ACK 時該列不是 pending：$(status_of "$ida")"
fail_n="$(jq -s --arg id "$ida" '[.[] | select(.job_id==$id and .status=="FAIL")] | length' "$MYTHOS_DIR/state/events.jsonl")"
[ "$fail_n" = 1 ] || fail "8：沒有正好一則 FAIL 事件：$(cat "$MYTHOS_DIR/state/events.jsonl" 2>&1)"
jq -e --arg id "$ida" 'select(.job_id==$id and .status=="FAIL" and (.extra | contains("runner 未啟動")))' "$MYTHOS_DIR/state/events.jsonl" >/dev/null \
  || fail "8：FAIL 的 extra 沒帶 runner 未啟動：$(cat "$MYTHOS_DIR/state/events.jsonl" 2>&1)"
[ "$(status_of "$idb")" = pending ] || fail "8：A 釋放後 B 沒被拉起：$(status_of "$idb")"
[ "$(started "$idb")" = 1 ] || fail '8：B 沒啟動 runner'
watch
[ "$(jq -s --arg id "$ida" '[.[] | select(.job_id==$id)] | length' "$MYTHOS_DIR/state/events.jsonl")" = 1 ] || fail '8：failed 的票下一輪又發事件'

# 8b) F4：state 可寫，只有事件寫入失敗 → 一輪照寫 handoff＋rc=127，列仍 pending、沒有 FAIL；
#     恢復 → 下一輪恰好一則 FAIL（同 event_id 只一則）；模擬 ACK → 列轉 notified-FAIL。
#     注入點：lib-events.mjs 寫入＝同目錄暫存檔＋rename，events.jsonl 設 uchg（不可變旗標）→ rename 拿 EPERM，
#     讀取照常、state 目錄與兩把鎖都不受影響（chmod 444 擋不住 rename，目錄唯讀會連 watcher 鎖都建不了）。
section f3b
printf '#!/bin/sh\nexit 1\n' > "$H/dead2-runner"; chmod +x "$H/dead2-runner"
# 照 tests/test_dispatch_watch.sh 的 ACK 手法：send-keys -l 的文字追加成一筆 user 紀錄進 transcript；capture-pane 回閒置畫面
cat > "$H/tmux-ack" <<'FAKETMUX'
#!/bin/sh
case " $* " in
  " -L mythos send-keys -t mythos -l "*)esc="$(printf '%s' "$8" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$esc" >> "$MYTHOS_TRANSCRIPT_DIR/router.jsonl" ;;
  *" capture-pane "*) printf 'idle screen\n' ;;
esac
exit 0
FAKETMUX
chmod +x "$H/tmux-ack"
: > "$TMP/tG-a.md"
idh="$(DISPATCH_DEEP_RUN_BIN="$H/dead2-runner" dispatch "$TMP/tG-a.md" "$TMP/repoH")"
old=$(( $(date +%s) - 121 ))
awk -v id="$idh" -v t="$old" -F'\t' 'BEGIN{OFS="\t"} $1==id { $4=t } { print }' "$TSV" > "$TSV.k" && mv "$TSV.k" "$TSV"
EV="$MYTHOS_DIR/state/events.jsonl"
: > "$EV"
chflags uchg "$EV" || fail '8b：設不了 uchg，事件寫入失敗做不出來'
TMUX_BIN="$H/tmux-ack" watch
[ "$(tr -d '[:space:]' < "$MYTHOS_DIR/state/deep/$idh.rc")" = 127 ] || fail '8b：事件寫不進去就連 rc 都沒寫'
[ "$(status_of "$idh")" = pending ] || fail "8b：事件寫不進去時列變了：$(status_of "$idh")"
[ ! -s "$EV" ] || fail "8b：uchg 沒擋住事件寫入：$(cat "$EV")"
jq -e --arg id "$idh" 'select(.job_id==$id and .status=="FAIL")' "$EV" >/dev/null 2>&1 && fail '8b：事件寫不進去卻有 FAIL'
chflags nouchg "$EV"
TMUX_BIN="$H/tmux-ack" watch   # 恢復：這輪建 FAIL 並送進 transcript；ACK 掃描在投遞之前，下一輪才看得到
[ "$(jq -s --arg id "$idh" '[.[] | select(.job_id==$id and .status=="FAIL")] | length' "$EV")" = 1 ] \
  || fail "8b：恢復後不是恰好一則 FAIL：$(cat "$EV" 2>&1)"
[ "$(status_of "$idh")" = pending ] || fail "8b：未 ACK 就改了狀態：$(status_of "$idh")"
grep -qF "event_id=${idh}-FAIL" "$MYTHOS_TRANSCRIPT_DIR/router.jsonl" || fail "8b：恢復那輪沒送出事件：$(tail -1 "$MYTHOS_TRANSCRIPT_DIR/router.jsonl")"
TMUX_BIN="$H/tmux-ack" watch   # 掃到 ACK
[ "$(jq -s --arg id "$idh" '[.[] | select(.job_id==$id and .status=="FAIL")] | length' "$EV")" = 1 ] \
  || fail "8b：ACK 那輪又發了 FAIL：$(cat "$EV" 2>&1)"
[ "$(status_of "$idh")" = notified-FAIL ] || fail "8b：ACK 後不是 notified-FAIL：$(status_of "$idh")"

# 8c) F1：票已落地（rc 已寫／ledger 列非 pending）→ 遲到的 runner 不啟動、不寫 handle
printf '#!/bin/sh\necho "$*" >> "%s"
' "$STUB_LOG" > "$H/late-runner"; chmod +x "$H/late-runner"
: > "$TMP/tG-b.md"
section f1
n0="$(wc -l < "$STUB_LOG" | tr -d ' ')"
printf '0\n' > "$MYTHOS_DIR/state/deep/land-rc.rc"
MYTHOS_DIR="$MYTHOS_DIR" DEEP_RUN_BIN="$H/late-runner" bash "$ROOT/bin/dispatch-deep-run" land-rc "$TMP/tG-b.md" "$TMP/repoH" 2>"$H/late.err" || fail "8c：rc 已存在時 runner 非零退出：$(cat "$H/late.err")"
[ "$(wc -l < "$STUB_LOG" | tr -d ' ')" = "$n0" ] || fail '8c：rc 已存在卻還是呼叫了 deep-run'
[ ! -f "$MYTHOS_DIR/state/deep/land-rc.handle" ] || fail '8c：rc 已存在卻寫了 handle'
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' land-fail hard "$TMP/tG-b.md" "$(date +%s)" failed "$TMP/repoH" - deep >> "$TSV"
MYTHOS_DIR="$MYTHOS_DIR" DEEP_RUN_BIN="$H/late-runner" bash "$ROOT/bin/dispatch-deep-run" land-fail "$TMP/tG-b.md" "$TMP/repoH" 2>"$H/late.err" || fail "8c：列 failed 時 runner 非零退出：$(cat "$H/late.err")"
[ "$(wc -l < "$STUB_LOG" | tr -d ' ')" = "$n0" ] || fail '8c：列 failed 卻還是呼叫了 deep-run'
[ ! -f "$MYTHOS_DIR/state/deep/land-fail.handle" ] || fail '8c：列 failed 卻寫了 handle'

# 8d) F1：handoff 與 runner 寫 handle 交錯。真的做出交錯：測試先拿走 ledger 鎖，watcher 掃 ledger 時還沒有 handle、
#     進 fail_handoff 卡在拿鎖；這時才寫 handle（模擬 runner 在鎖內寫第一版 handle）再放鎖
#     → 鎖內重查看到 handle：沒有 rc、沒有 handoff，同 top 的 queued 不被拉起
section f1x
row ia $(( $(date +%s) - 300 )) pending "$TMP/repoI"
row ia-q "$(date +%s)" queued "$TMP/repoI"
LF="$MYTHOS_DIR/state/.ledger.flock"; : > "$LF"
perl -MFcntl=:flock -e 'open(my $f,">>",$ARGV[0]) or exit 2; flock($f,LOCK_EX) or exit 3; open(my $m,">",$ARGV[1]); close $m;
  for (1..300) { exit 0 if -e $ARGV[2]; select(undef,undef,undef,0.1) } exit 4' "$LF" "$H/held" "$H/release" &
holder=$!; BG_PIDS+=("$holder")
for _ in $(seq 50); do [ -e "$H/held" ] && break; sleep 0.1; done
[ -e "$H/held" ] || fail '8d：測試拿不到 ledger 鎖'
: > "$STUB_LOG"
bash "$ROOT/bin/dispatch-watch" 9>&- & wpid=$!; BG_PIDS+=("$wpid")
# watcher 打開鎖檔（ledger_lock 的 exec 9>>）＝已過鎖外檢查、正在等鎖；0a 是 watcher 第一個拿 ledger 鎖的地方
seen=''
for _ in $(seq 80); do
  if lsof -t -- "$LF" 2>/dev/null | grep -vx "$holder" | grep -q .; then seen=1; break; fi
  sleep 0.1
done
[ -n "$seen" ] || fail '8d：watcher 沒有卡在 ledger 鎖，交錯沒做出來'
[ ! -e "$MYTHOS_DIR/state/deep/ia.rc" ] || fail '8d：還沒拿到鎖就寫了 rc'
printf 'pid=1\n' > "$MYTHOS_DIR/state/deep/ia.handle"
: > "$H/release"
wait "$holder" || fail '8d：鎖持有者異常結束'
wait "$wpid" || fail '8d：dispatch-watch 非零退出'
track
[ ! -e "$MYTHOS_DIR/state/deep/ia.rc" ] || fail '8d：鎖內已有 handle 仍寫了 rc'
[ ! -e "$MYTHOS_DIR/state/deep/ia.handoff" ] || fail '8d：鎖內已有 handle 仍寫了 handoff'
[ "$(status_of ia-q)" = queued ] || fail "8d：handle 在、票還在跑，同 top 的 queued 卻被拉起：$(status_of ia-q)"
[ "$(started ia-q)" = 0 ] || fail '8d：同 top 的 queued 啟動了 runner'

# 8e) F3：原因寫不進去（handoff 目的地預先建成目錄）→ 這輪不寫 rc；移除後下一輪 rc=127＋原因
section f3c
row ib $(( $(date +%s) - 300 )) pending "$TMP/repoJ"
mkdir "$MYTHOS_DIR/state/deep/ib.handoff"
watch
[ ! -e "$MYTHOS_DIR/state/deep/ib.rc" ] || fail '8e：原因寫不進去仍寫了 rc'
rmdir "$MYTHOS_DIR/state/deep/ib.handoff"
watch
[ "$(tr -d '[:space:]' < "$MYTHOS_DIR/state/deep/ib.rc" 2>/dev/null)" = 127 ] || fail '8e：原因可寫後沒寫 rc=127'
grep -q 'runner 未啟動' "$MYTHOS_DIR/state/deep/ib.handoff" || fail "8e：handoff 檔沒寫原因：$(cat "$MYTHOS_DIR/state/deep/ib.handoff" 2>&1)"

# 9) F5：入列 7 小時的 queued 升級 → epoch 改成升級當下；dispatch-watch 不發 REVIEW、watchdog 不告警 pending 逾 6 小時
section f5
row g-done $((NOW - 25300)) pending "$TMP/repoG"; printf '0\n' > "$MYTHOS_DIR/state/deep/g-done.rc"
row g-q $((NOW - 25200)) queued "$TMP/repoG"
: > "$STUB_LOG"
t0="$(date +%s)"
watch
track
[ "$(status_of g-q)" = pending ] || fail "9：g-q 沒被升級：$(status_of g-q)"
[ "$(epoch_of g-q)" -ge "$t0" ] || fail "9：升級後 epoch 還是入列時間：$(epoch_of g-q)"
jq -e 'select(.job_id=="g-q" and .status=="REVIEW")' "$MYTHOS_DIR/state/events.jsonl" >/dev/null 2>&1 && fail '9：剛升級就發 REVIEW'
rm -rf "$H/brief"
MYTHOS_BRIEF_DIR="$H/brief" WATCHDOG_CLAUDE_BIN="$H/true" WATCHDOG_LLM_LEGS="$H/false" WATCHDOG_SCRUB_CMD="$H/false" \
  WATCHDOG_CANARY_CMD="$H/true" WATCHDOG_LLM_TIMEOUT_S=3 bash "$ROOT/bin/watchdog" >/dev/null 2>&1 || true
grep -F 'g-q' "$H/brief/mythos-watchdog.tsv" 2>/dev/null | grep -q '卡在 pending' && fail '9：剛升級的票被當成 pending 逾 6 小時'
# 對照：同一份 watchdog 對真的老 pending 會告警（確認上一行不是因為 watchdog 沒跑）
row g-old $((NOW - 25200)) pending "$TMP/repoC"; printf 'fixture=1\n' > "$MYTHOS_DIR/state/deep/g-old.handle"
rm -rf "$H/brief"
MYTHOS_BRIEF_DIR="$H/brief" WATCHDOG_CLAUDE_BIN="$H/true" WATCHDOG_LLM_LEGS="$H/false" WATCHDOG_SCRUB_CMD="$H/false" \
  WATCHDOG_CANARY_CMD="$H/true" WATCHDOG_LLM_TIMEOUT_S=3 bash "$ROOT/bin/watchdog" >/dev/null 2>&1 || true
grep -F 'g-old' "$H/brief/mythos-watchdog.tsv" 2>/dev/null | grep -q '卡在 pending' || fail "9：對照組老 pending 沒告警，上面的斷言無效：$(cat "$H/brief/mythos-watchdog.tsv" 2>&1)"

echo 'REPO-QUEUE PASS'
