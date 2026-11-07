#!/usr/bin/env bash
# WO4h：cutover／rollback 真路徑沙盒測試。全用 tmp 目錄＋假 launchctl／hermes／creds-exec，不碰真 launchd、不重啟真 gateway。
# (a) 成功 (b) 沒 Connected→exit 4＋自動回滾 byte 相同 (c) 寫 token 那步失敗→回滾＋舊 label 重新 bootstrap (d) 快照保留 (e) Conflict→失敗
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cutover-real.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
PY=$HOME/.hermes/hermes-agent/venv/bin/python
"$PY" -c 'import yaml' 2>/dev/null || fail "Hermes venv 沒有 PyYAML"

# ---- 假外部指令 ----
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/launchctl" <<'STUB'
#!/bin/sh
# 狀態檔模擬：$FAKE/lc/loaded.<label>；gateway pid 在 $FAKE/gw.pid
echo "$*" >> "$FAKE/lc.log"
case "$1" in
  print)
    l="${2##*/}"
    if [ "$l" = ai.hermes.gateway ]; then printf 'state = running\n\tpid = %s\n' "$(cat "$FAKE/gw.pid")"; exit 0; fi
    [ -f "$FAKE/lc/loaded.$l" ] || exit 113
    printf 'state = running\n\tpid = 1234\n'; exit 0 ;;
  bootout)
    l="${2##*/}"; [ -f "$FAKE/lc/loaded.$l" ] || exit 3
    rm -f "$FAKE/lc/loaded.$l"; exit 0 ;;
  bootstrap)
    l="$(basename "$3" .plist)"; [ -f "$3" ] || exit 5
    : > "$FAKE/lc/loaded.$l"; exit 0 ;;
esac
exit 64
STUB
cat > "$BIN/hermes" <<'STUB'
#!/bin/sh
[ "$1 $2" = "gateway restart" ] || exit 64
echo "restart" >> "$FAKE/hermes.log"
echo $(( $(cat "$FAKE/gw.pid") + 1 )) > "$FAKE/gw.pid"
mkdir -p "$(dirname "$FAKE_GW_LOG")"
echo "2026-11-07 restart pid $(cat "$FAKE/gw.pid")" >> "$FAKE_GW_LOG"
[ -z "${FAKE_NO_CONNECT:-}" ] && echo "INFO Connected to Telegram (polling mode)" >> "$FAKE_GW_LOG"
[ -n "${FAKE_CONFLICT:-}" ] && echo "WARN telegram.error.Conflict: terminated by other getUpdates request" >> "$FAKE_GW_LOG"
exit 0
STUB
cat > "$BIN/creds-exec" <<'STUB'
#!/bin/sh
n=$(( $(cat "$FAKE/creds.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/creds.n"
[ "$n" = "${FAKE_CREDS_FAIL_ON:-0}" ] && exit 1
while [ "$1" != "--" ]; do shift; done; shift
TELEGRAM_BOT_TOKEN=FAKE; export TELEGRAM_BOT_TOKEN
exec "$@"
STUB
cat > "$BIN/claude" <<'STUB'
#!/bin/sh
echo '[]'
STUB
chmod +x "$BIN"/*

STOPS="ai.mythos.telegram ai.mythos.idle-reset ai.mythos.watchdog"
KEEPL="ai.mythos.baw-keepalive ai.mythos.dispatch-watch"

# 每個情境一個全新沙盒：setup <name>，設 FAKE M P LA ENVV
setup() {
  S="$TMP/$1"; FAKE="$S/fake"; M="$S/mythos"; P="$S/profile"; LA="$S/la"
  mkdir -p "$FAKE/lc" "$M/state" "$P" "$LA"
  printf 'model: x\nother: 1\ngateway:\n  host: 127.0.0.1\n' > "$P/config.yaml"
  printf 'FOO=1\n' > "$P/.env"; chmod 600 "$P/.env"
  echo '{"dmPolicy":"allowlist","allowFrom":["1000000001"]}' > "$S/access.json"
  echo 100 > "$FAKE/gw.pid"
  for l in $STOPS $KEEPL; do : > "$LA/$l.plist"; : > "$FAKE/lc/loaded.$l"; done
  FAKE_GW_LOG="$P/logs/gateway.log"
}
cutover() { # 其餘環境變數由呼叫端 env 帶；回傳 rc 放 RC
  set +e
  env FAKE="$FAKE" FAKE_GW_LOG="$FAKE_GW_LOG" PATH="$BIN:$PATH" \
      LAUNCHCTL_BIN="$BIN/launchctl" HERMES_BIN="$BIN/hermes" CREDS_EXEC_BIN="$BIN/creds-exec" HERMES_PY="$PY" \
      HERMES_PROFILE_DIR="$P" MYTHOS_DIR="$M" MYTHOS_TG_ACCESS_JSON="$S/access.json" \
      CUTOVER_CLAUDE_BIN="$BIN/claude" CUTOVER_LA_DIR="$LA" MYTHOS_LEDGER="$S/none.tsv" GATEWAY_WAIT_SEC=3 \
      "$@" "$ROOT/bin/cutover-hermes" > "$S/out.txt" 2>&1 </dev/null
  RC=$?
  set -e
}
loaded() { [ -f "$FAKE/lc/loaded.$1" ]; }
keep_snapshot_orig() { mkdir -p "$S/orig"; cp "$P/config.yaml" "$S/orig/config.yaml"; cp "$P/.env" "$S/orig/env"; }
assert_restored() { # config／dotenv／deliver-mode 與切換前 byte 相同、舊 label 重新載入
  cmp "$S/orig/config.yaml" "$P/config.yaml" || fail "$1：config.yaml 沒回到原樣"
  cmp "$S/orig/env" "$P/.env" || fail "$1：dotenv 沒回到原樣"
  [ ! -e "$M/state/deliver-mode" ] || fail "$1：deliver-mode 原本不存在，回滾後還在"
  for l in $STOPS; do loaded "$l" || fail "$1：$l 回滾後沒重新載入"; done
  grep -q 'bootstrap' "$FAKE/lc.log" || fail "$1：沒呼叫 bootstrap"
}

# ---- (a) 真跑成功 ----
setup a; keep_snapshot_orig
cutover
[ "$RC" = 0 ] || fail "(a) 應 exit 0，得到 $RC：$(cat "$S/out.txt")"
"$PY" -c "
import yaml, sys
d = yaml.safe_load(open(sys.argv[1]))
t = d['gateway']['platforms']['telegram']
assert t['enabled'] is True, t
assert t['extra']['allow_from'] == ['1000000001'], t
assert d['other'] == 1 and d['gateway']['host'] == '127.0.0.1'
" "$P/config.yaml" || fail "(a) config.yaml 解析不到 telegram enabled／允許名單：$(cat "$P/config.yaml")"
[ "$(cat "$M/state/deliver-mode")" = hermes ] || fail "(a) deliver-mode 不是 hermes"
grep -q '^TELEGRAM_ALLOWED_USERS=1000000001$' "$P/.env" || fail "(a) dotenv 沒寫白名單"
grep -q '^TELEGRAM_BOT_TOKEN=FAKE$' "$P/.env" || fail "(a) dotenv 沒寫假 token"
grep -q '^FOO=1$' "$P/.env" || fail "(a) dotenv 其他鍵被動到"
for l in $STOPS; do
  grep -q "bootout gui/.*/$l\$" "$FAKE/lc.log" || fail "(a) $l 沒被 bootout"
  loaded "$l" && fail "(a) $l 還載入"
done
for l in $KEEPL; do
  grep -q "$l" "$FAKE/lc.log" && fail "(a) 保留的 $l 被碰了"
  loaded "$l" || fail "(a) 保留的 $l 不見了"
done
[ -f "$M/state/cutover-snapshot/complete" ] || fail "(a) 沒建快照"
[ "$(stat -f %Lp "$M/state/cutover-snapshot/env.orig")" = 600 ] || fail "(a) 快照權限不是 600"
grep -q 'Connected to Telegram' "$P/logs/gateway.log" || fail "(a) 假 log 沒 Connected"
grep -q FAKE "$S/out.txt" && fail "(a) token 值出現在輸出"

# ---- (d) 快照已存在，再跑一次，快照內容不變 ----
snap_sum() { (cd "$M/state/cutover-snapshot" && find . -type f | sort | while read -r f; do shasum -a 256 "$f"; done); }
before="$(snap_sum)"
cutover
[ "$RC" = 0 ] || fail "(d) 第二次跑應 exit 0，得到 $RC：$(cat "$S/out.txt")"
[ "$(snap_sum)" = "$before" ] || fail "(d) 快照內容被覆寫"
grep -q '快照已存在' "$S/out.txt" || fail "(d) 沒說保留原快照"
cmp "$S/orig/env" "$M/state/cutover-snapshot/env.orig" || fail "(d) 快照不是最初 dotenv"

# ---- (a2) 手動回滾精確還原 ----
set +e
env FAKE="$FAKE" FAKE_GW_LOG="$FAKE_GW_LOG" LAUNCHCTL_BIN="$BIN/launchctl" HERMES_BIN="$BIN/hermes" CREDS_EXEC_BIN="$BIN/creds-exec" HERMES_PY="$PY" \
    HERMES_PROFILE_DIR="$P" MYTHOS_DIR="$M" CUTOVER_LA_DIR="$LA" GATEWAY_WAIT_SEC=3 "$ROOT/bin/rollback-mythos" > "$S/rb.txt" 2>&1 </dev/null
rc=$?; set -e
[ "$rc" = 0 ] || fail "(a2) rollback-mythos 應 0，得到 $rc：$(cat "$S/rb.txt")"
grep -q '回滾完成' "$S/rb.txt" || fail "(a2) 沒印回滾完成"
assert_restored "(a2)"

# ---- (b) 沒 Connected → exit 4＋自動回滾 ----
setup b; keep_snapshot_orig
cutover FAKE_NO_CONNECT=1
[ "$RC" = 4 ] || fail "(b) 應 exit 4，得到 $RC：$(cat "$S/out.txt")"
assert_restored "(b)"
grep -q '回滾完成' "$S/out.txt" || fail "(b) 沒驗到回滾完成"
[ "$(grep -c restart "$FAKE/hermes.log")" = 2 ] || fail "(b) 應 restart 兩次（切換＋回滾）"

# ---- (c) 寫 token 那步失敗（creds-exec 第 2 次呼叫）→ 回滾、舊 label 重新 bootstrap ----
setup c; keep_snapshot_orig
cutover FAKE_CREDS_FAIL_ON=2
[ "$RC" = 4 ] || fail "(c) 應 exit 4，得到 $RC：$(cat "$S/out.txt")"
assert_restored "(c)"
for l in $STOPS; do grep -q "bootstrap gui/.* $LA/$l.plist" "$FAKE/lc.log" || fail "(c) $l 沒被重新 bootstrap"; done

# ---- (e) log 出現 Conflict → 判失敗 ----
setup e; keep_snapshot_orig
cutover FAKE_CONFLICT=1
[ "$RC" = 4 ] || fail "(e) Conflict 應 exit 4，得到 $RC：$(cat "$S/out.txt")"
grep -q 'Conflict' "$S/out.txt" || fail "(e) 輸出沒提 Conflict"
assert_restored "(e)"

# ---- (f) 前置檢查失敗不動任何服務：creds 第 1 次（precheck）就失敗 ----
setup f; keep_snapshot_orig
cutover FAKE_CREDS_FAIL_ON=1
[ "$RC" = 1 ] || fail "(f) precheck 失敗應 exit 1，得到 $RC：$(cat "$S/out.txt")"
grep -q 'bootout' "$FAKE/lc.log" 2>/dev/null && fail "(f) precheck 失敗卻 bootout 了"
[ ! -e "$M/state/cutover-snapshot" ] || fail "(f) precheck 失敗不該建快照"
for l in $STOPS; do loaded "$l" || fail "(f) $l 被動到"; done

echo "PASS test-cutover-real-sandbox"
