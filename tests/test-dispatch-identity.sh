#!/usr/bin/env bash
# 11-08 差距 #6：派工入口先驗參數、取消先核身分。
# (a) mythos_dispatch 的 thread 不合 ^t-[a-z0-9]{4,16}$（../x、/tmp/x、50 字元）→ 回錯誤、沙箱 MYTHOS_DIR 內零新檔
# (b) dispatch-bg 起 hermes worker 會寫 state/bg/<sid>.pid_start
# (c) pid_start 不符 → 不殺、輸出含 cancel_failed、結束碼非 0、ledger 仍 pending
# (d) pid_start 相符 → 假程序被殺、ledger 標 cancelled
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-identity.XXXXXX")"
cleanup() {
  for f in "$TMP"/*/state/bg/*.pid "$TMP"/gc-*.pid; do
    [ -f "$f" ] || continue
    p="$(tr -d '[:space:]' < "$f" 2>/dev/null || true)"
    [ -n "$p" ] && { pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; }
  done
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------- (a) thread 驗參 ----------
SB="$TMP/sandbox"
mkdir -p "$SB/state"
TBAD="$(printf 't-%050d' 7)"
cat > "$TMP/probe.py" <<'PY'
import importlib.util, os, sys
plugin = sys.argv[1]
spec = importlib.util.spec_from_file_location("mt_probe", plugin)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

def snapshot():
    out = set()
    for base, dirs, files in os.walk(os.environ["MYTHOS_DIR"]):
        for n in files:
            out.add(os.path.join(base, n))
    return out

before = snapshot()
for bad in ("../x", "/tmp/x", os.environ["TBAD"]):
    for kw in ({"request": "做事"}, {"request": "做事", "mode": "cancel"},
               {"request": "做事", "mode": "interrupt"}):
        res = m.mythos_dispatch(dict(kw, thread=bad))
        assert "thread" in res and "格式" in res, (bad, kw, res)
after = snapshot()
new = after - before
assert not new, f"thread 不合規仍寫了檔：{sorted(new)}"
# 對照：合規代號照舊可派（DRYRUN，不叫 dispatch-bg），只寫記帳一行
res = m.mythos_dispatch({"request": "做事", "thread": "t-abc123"})
assert res == "已派 t-abc123", res
log = os.path.join(os.environ["MYTHOS_DIR"], "state", "router-dispatch.log")
assert open(log, encoding="utf-8").read().count("\n") == 1, open(log).read()
# 自動產生的代號也合規
res = m.mythos_dispatch({"request": "做事"})
tid = res.split()[-1]
assert m.THREAD_RE.fullmatch(tid), (res, tid)
print("VALIDATE_OK")
PY
MYTHOS_DIR="$SB" MYTHOS_DISPATCH_DRYRUN=1 TBAD="$TBAD" \
  python3 "$TMP/probe.py" "$HOME/.hermes/profiles/mythos/plugins/mythos-tools/__init__.py" \
  || fail "(a) thread 驗參失敗"
echo '(a) ok'

# ---------- (b)(c)(d) 取消核身分 ----------
export DISPATCH_BG_HERMES_BIN="$TMP/hermes" HERMES_LOG="$TMP/hermes.log" GC_DIR="$TMP"
export CLAUDE_BIN="$TMP/claude" FAKE_AGENTS="$TMP/agents.json" FAKE_ID="$TMP/fake-id"
export DCQ_HOME="$TMP/dcq" ROUTER_SLUG="identity-test-$$" DISPATCH_BG_NO_TRIGGER=1 BG_AUTOHEAL=0
mkdir -p "$TMP/dcq" "$TMP/rt"
echo '[]' > "$FAKE_AGENTS"; echo cafe0005-0000-0000-0000-000000000000 > "$FAKE_ID"
printf '#!/bin/sh\n[ "${1:-}" = agents ] && { cat "$FAKE_AGENTS"; exit 0; }\nexit 0\n' > "$CLAUDE_BIN"
# 假 hermes：記 argv、起孫行程 sleep 300、自己等它
cat > "$DISPATCH_BG_HERMES_BIN" <<'STUB'
#!/bin/sh
printf 'CALL\t%s\n' "$*" >> "$HERMES_LOG"
sleep 300 &
echo $! >> "$GC_DIR/gc-$$.pid"
wait
STUB
chmod +x "$CLAUDE_BIN" "$DISPATCH_BG_HERMES_BIN"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$TMP/rt/r.jsonl"
export MYTHOS_TRANSCRIPT_DIR="$TMP/rt" CLAUDE_PROJECTS_DIR="$TMP/projects"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"
alive() { kill -0 "$1" 2>/dev/null; }
row_st() { awk -F'\t' -v i="$1" '$1==i {print $5}' "$MYTHOS_DIR/state/dispatch-jobs.tsv"; }
start_job() { # tag → 印 id
  export MYTHOS_DIR="$TMP/m-$1" MYTHOS_WORKER_DIR="$TMP/w-$1"
  mkdir -p "$MYTHOS_DIR/state/bg" "$MYTHOS_WORKER_DIR"
  rm -f "$TMP"/gc-*.pid
  printf '把 JOB-%s 做完\n' "$1" > "$TMP/p-$1.md"
  DISPATCH_BG_WORKER=hermes bash "$ROOT/bin/dispatch-bg" "t-$1" "$TMP/p-$1.md" 9>&- >"$TMP/id-$1.out" 2>"$TMP/id-$1.err" \
    || fail "(b) dispatch-bg 起不來：$(cat "$TMP/id-$1.err")"
  head -1 "$TMP/id-$1.out"
}

# (b) pid_start 有寫、跟 ps 對得上
id1="$(start_job c1)"; sid1="${id1#bg-}"
export MYTHOS_DIR="$TMP/m-c1"  # start_job 在子殼裡 export，這裡沿用同一個沙箱
psf="$MYTHOS_DIR/state/bg/$sid1.pid_start"
for i in $(seq 1 50); do [ -s "$psf" ] && break; sleep 0.1; done
[ -s "$psf" ] || fail "(b) 沒寫 pid_start"
hp1="$(tr -d '[:space:]' < "$MYTHOS_DIR/state/bg/$sid1.pid")"
norm() { printf '%s' "$1" | sed 's/  */ /g; s/^ //; s/ $//'; }
[ "$(norm "$(cat "$psf")")" = "$(norm "$(ps -o lstart= -p "$hp1" 2>/dev/null)")" ] || fail "(b) pid_start 跟 ps 對不上：$(cat "$psf")"
for i in $(seq 1 50); do ls "$TMP"/gc-*.pid >/dev/null 2>&1 && break; sleep 0.1; done
g1="$(cat "$(ls "$TMP"/gc-*.pid | head -1)")"
echo '(b) ok'

# (c) pid_start 不符 → 不殺、cancel_failed、非 0、ledger 仍 pending
printf 'Thu Jan  1 00:00:00 1970\n' > "$psf"
rc=0; out="$(bash "$ROOT/bin/dispatch-cancel" "$id1" 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "(c) 身分不符仍 exit 0：$out"
case "$out" in *cancel_failed*) ;; *) fail "(c) 輸出沒有 cancel_failed：$out" ;; esac
sleep 0.3
alive "$hp1" || fail "(c) 身分不符卻殺了 worker"
alive "$g1" || fail "(c) 身分不符卻殺了孫行程"
[ "$(row_st "$id1")" = pending ] || fail "(c) ledger 被改：$(row_st "$id1")"
# 缺 pid_start 也一樣不殺
rm -f "$psf"
rc=0; out="$(bash "$ROOT/bin/dispatch-cancel" "$id1" 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "(c) 缺 pid_start 仍 exit 0：$out"
case "$out" in *cancel_failed*) ;; *) fail "(c) 缺 pid_start 沒 cancel_failed：$out" ;; esac
alive "$hp1" || fail "(c) 缺 pid_start 卻殺了 worker"
[ "$(row_st "$id1")" = pending ] || fail "(c) 缺 pid_start ledger 被改：$(row_st "$id1")"
echo '(c) ok'

# (d) 身分相符 → 殺掉、ledger cancelled
norm "$(ps -o lstart= -p "$hp1")" > "$psf"
[ -s "$psf" ] || fail "(d) 寫不回 pid_start"
rc=0; out="$(bash "$ROOT/bin/dispatch-cancel" "$id1" 2>&1)" || rc=$?
[ "$rc" = 0 ] || fail "(d) 身分相符取消失敗（rc=$rc）：$out"
[ "$(row_st "$id1")" = cancelled ] || fail "(d) ledger 應 cancelled：$(row_st "$id1")"
for i in $(seq 1 30); do alive "$hp1" || break; sleep 0.1; done
alive "$hp1" && fail "(d) 子殼 $hp1 沒被殺"
sleep 1
alive "$g1" && fail "(d) 孫行程 $g1 沒被殺"
echo '(d) ok'
echo 'IDENTITY_OK'
