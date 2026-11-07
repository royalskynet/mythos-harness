#!/usr/bin/env bash
# WO4：cutover/rollback --dry-run 不動現況（config.yaml sha、launchd state 不變），假 claude 回 running 的 mythos-worker 就 exit 3。
# 另在 tmp 沙盒跑一次真路徑（HERMES_PROFILE_DIR 指假 profile）驗 render_platform／env_put 的結果，不碰真的 profile。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cutover-dryrun.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
UID_="$(id -u)"
fail() { echo "FAIL: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
# 假 launchctl（狀態檔模擬）；本檔任何地方都不叫真 launchctl
FAKE="$TMP/fake"; mkdir -p "$FAKE/lc"; echo 100 > "$FAKE/gw.pid"
FAKE_LC="$TMP/launchctl"
cat > "$FAKE_LC" <<'STUB'
#!/bin/sh
case "$1" in
  print) l="${2##*/}"
    if [ "$l" = ai.hermes.gateway ]; then printf 'state = running\n\tpid = %s\n' "$(cat "$FAKE/gw.pid")"; exit 0; fi
    [ -f "$FAKE/lc/loaded.$l" ] || exit 113; printf 'state = running\n\tpid = 1234\n' ;;
  bootout) l="${2##*/}"; [ -f "$FAKE/lc/loaded.$l" ] || exit 3; rm -f "$FAKE/lc/loaded.$l" ;;
  bootstrap) l="$(basename "$3" .plist)"; [ -f "$3" ] || exit 5; : > "$FAKE/lc/loaded.$l" ;;
  *) exit 64 ;;
esac
STUB
chmod +x "$FAKE_LC"
export LAUNCHCTL_BIN="$FAKE_LC" FAKE
state_line() { "$FAKE_LC" print "gui/$UID_/$1" 2>/dev/null | grep -m1 'state =' || echo 'not loaded'; }

export HOME_ORIG="$HOME"
CFG="$HOME_ORIG/.hermes/config.yaml"
cfgs="$(sha "$CFG")"; st_tg="$(state_line ai.mythos.telegram)"

# (1) 兩支 dry-run exit 0、輸出含 ai.mythos.telegram、不 bootout
"$ROOT/bin/cutover-hermes" --dry-run > "$TMP/cut.out" 2>&1 || fail "cutover --dry-run exit $?：$(cat "$TMP/cut.out")"
grep -q 'ai.mythos.telegram' "$TMP/cut.out" || fail "cutover dry-run 沒提 ai.mythos.telegram"
"$ROOT/bin/rollback-mythos" --dry-run > "$TMP/rb.out" 2>&1 || fail "rollback --dry-run exit $?：$(cat "$TMP/rb.out")"
grep -q 'ai.mythos.telegram' "$TMP/rb.out" || fail "rollback dry-run 沒提 ai.mythos.telegram"
[ ! -e "$HOME/.hermes/profiles/mythos/.env.allowleak" ] || fail "不該有殘檔"

# (2) config.yaml sha 不變、telegram launchd state 不變
[ "$(sha "$CFG")" = "$cfgs" ] || fail "config.yaml sha 變了"
[ "$(state_line ai.mythos.telegram)" = "$st_tg" ] || fail "ai.mythos.telegram state 變了：$st_tg → $(state_line ai.mythos.telegram)"

# (3) 假 claude：回一個 running 的 mythos-worker 項 → exit 3（真 claude 也不准被叫到）
cat > "$TMP/claude" <<'STUB'
#!/bin/sh
[ "$1" = agents ] || exit 9
echo '[{"pid":4242,"cwd":"~/bots/mythos/router/worker","status":"running"}]'
STUB
chmod +x "$TMP/claude"
set +e
out="$(CUTOVER_CLAUDE_BIN="$TMP/claude" "$ROOT/bin/cutover-hermes" --dry-run 2>&1)"; rc=$?
set -e
[ $rc -eq 3 ] || fail "假 claude 有 running worker 應 exit 3，得到 $rc：$out"
printf '%s' "$out" | grep -q 4242 || fail "exit 3 訊息沒帶 pid：$out"
[ "$(sha "$CFG")" = "$cfgs" ] || fail "exit 3 前動了 config.yaml"

# (3b) 假 claude 沒有 worker＋ledger 未完單 → dry-run 仍 0；ledger 有 doing 單 → 3
cat > "$TMP/claude-idle" <<'STUB'
#!/bin/sh
echo '[]'
STUB
chmod +x "$TMP/claude-idle"
CUTOVER_CLAUDE_BIN="$TMP/claude-idle" MYTHOS_LEDGER="$TMP/none.tsv" "$ROOT/bin/cutover-hermes" --dry-run >/dev/null 2>&1 || fail "無 worker 時 dry-run 應 0"
printf 'job_id\tthread\tstatus\nbg-1\tt\tdoing\n' > "$TMP/ledger.tsv"
set +e
CUTOVER_CLAUDE_BIN="$TMP/claude-idle" MYTHOS_LEDGER="$TMP/ledger.tsv" "$ROOT/bin/cutover-hermes" --dry-run >/dev/null 2>&1; rc=$?
set -e
[ $rc -eq 3 ] || fail "ledger 有 doing 單應 exit 3，得到 $rc"

# (4) 沙盒真路徑：假 profile、假 hermes／launchctl／creds-exec、假 MYTHOS_DIR（細項見 tests/test-cutover-real-sandbox.sh）
M="$TMP/mythos"; P="$TMP/profile"
mkdir -p "$M/state" "$P" "$TMP/la" "$FAKE/lc"
printf 'model: x\ngateway:\n  host: 127.0.0.1\n  platforms: {}\nother: 1\n' > "$P/config.yaml"
printf 'FOO=1\n' > "$P/.env"
echo '{"dmPolicy":"allowlist","allowFrom":["1000000001"]}' > "$TMP/access.json"
echo 100 > "$FAKE/gw.pid"
for l in ai.mythos.telegram ai.mythos.idle-reset ai.mythos.watchdog; do : > "$TMP/la/$l.plist"; : > "$FAKE/lc/loaded.$l"; done
cat > "$TMP/hermes" <<'STUB'
#!/bin/sh
echo $(( $(cat "$FAKE/gw.pid") + 1 )) > "$FAKE/gw.pid"
mkdir -p "$(dirname "$FAKE_GW_LOG")"; echo "INFO Connected to Telegram (polling mode)" >> "$FAKE_GW_LOG"
STUB
cat > "$TMP/creds-exec" <<'STUB'
#!/bin/sh
while [ "$1" != "--" ]; do shift; done; shift
TELEGRAM_BOT_TOKEN=FAKE; export TELEGRAM_BOT_TOKEN; exec "$@"
STUB
chmod +x "$TMP/hermes" "$TMP/creds-exec"
set +e
env FAKE_GW_LOG="$P/logs/gateway.log" HOME="$TMP/home" MYTHOS_DIR="$M" HERMES_PROFILE_DIR="$P" HERMES_BIN="$TMP/hermes" \
    CREDS_EXEC_BIN="$TMP/creds-exec" GATEWAY_WAIT_SEC=3 \
    MYTHOS_TG_ACCESS_JSON="$TMP/access.json" CUTOVER_CLAUDE_BIN="$TMP/claude-idle" CUTOVER_LA_DIR="$TMP/la" \
    "$ROOT/bin/cutover-hermes" > "$TMP/real.out" 2>&1 </dev/null
rc=$?
set -e
[ $rc -eq 0 ] || fail "沙盒真跑 exit $rc：$(cat "$TMP/real.out")"
grep -q 'allow_from:' "$P/config.yaml" && grep -q '1000000001' "$P/config.yaml" || fail "config.yaml 沒寫白名單：$(cat "$P/config.yaml")"
grep -q 'TELEGRAM_ALLOWED_USERS=1000000001' "$P/.env" || fail ".env 沒寫白名單"
grep -q '^other: 1' "$P/config.yaml" || fail "config.yaml 其他鍵被動到"
grep -q '^FOO=1' "$P/.env" || fail ".env 其他鍵被動到"
[ -f "$P/config.yaml.bak-cutover" ] || fail "沒備份 config.yaml"
[ "$(cat "$M/state/deliver-mode")" = hermes ] || fail "deliver-mode 沒寫"
python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); assert d['gateway']['platforms']['telegram']['enabled'] is True; assert d['gateway']['platforms']['telegram']['extra']['allow_from']==['1000000001']" "$P/config.yaml" \
  || fail "config.yaml 不是合法 YAML 或 telegram 段不對"

# (4b) 回滾真路徑（沙盒）：照快照還原
env FAKE_GW_LOG="$P/logs/gateway.log" HOME="$TMP/home" MYTHOS_DIR="$M" HERMES_PROFILE_DIR="$P" HERMES_BIN="$TMP/hermes" \
    GATEWAY_WAIT_SEC=3 CUTOVER_LA_DIR="$TMP/la" \
    "$ROOT/bin/rollback-mythos" > "$TMP/rb2.out" 2>&1 || fail "沙盒 rollback 失敗：$(cat "$TMP/rb2.out")"
[ ! -e "$M/state/deliver-mode" ] || fail "rollback 沒刪 deliver-mode"
! grep -q 'TELEGRAM_ALLOWED_USERS' "$P/.env" || fail "rollback 沒拿掉 dotenv 鍵"
! grep -q 'telegram' "$P/config.yaml" || fail "rollback 沒拿掉 telegram 段：$(cat "$P/config.yaml")"
grep -q 'host: 127.0.0.1' "$P/config.yaml" || fail "rollback 傷到 gateway 其他鍵"
[ -f "$FAKE/lc/loaded.ai.mythos.telegram" ] || fail "rollback 沒把 telegram 拉回來"

# (5) 全程不碰真的 config.yaml（launchd 全用假 launchctl）
[ "$(sha "$CFG")" = "$cfgs" ] || fail "config.yaml sha 變了"
[ "$(state_line ai.mythos.telegram)" = "state = running" ] || fail "沙盒回滾後 ai.mythos.telegram 沒回到 running"

echo "PASS test-cutover-dryrun"
