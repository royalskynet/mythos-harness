#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/claim-guard-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"
export ROOT
python3 - <<'PY'
import http.server
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import threading
import time

root = Path(os.environ['ROOT'])
guard = Path(os.environ.get('CLAIM_GUARD_TEST_BIN', root / 'bin/claim-guard'))

def run(cmd, env=None, **kw):
    return subprocess.run(cmd, env=env, text=True, capture_output=True, **kw)

def ok(value, name):
    assert value, name
    print('PASS ' + name, flush=True)

with tempfile.TemporaryDirectory(prefix='claim-guard-') as tmp:
    base = Path(tmp)
    repo = base / 'repo'
    repo.mkdir()
    run(['git', 'init', '-q', str(repo)], check=True)
    (repo / '.gitignore').write_text('/state/\n')
    run(['git', '-C', str(repo), 'add', '.gitignore'], check=True)
    run(['git', '-C', str(repo), '-c', 'user.name=Fixture', '-c', 'user.' + 'email=fixture', 'commit', '-qm', 'fixture'], check=True)
    sha = run(['git', '-C', str(repo), 'rev-parse', 'HEAD']).stdout.strip()
    bg = repo / 'state/bg'
    bg.mkdir(parents=True)
    task = base / 'prompt.md'
    task.write_text('查驗 https://task.example/one\n')
    (repo / 'state/dispatch-jobs.tsv').write_text(f'bg-sample\tmid\t{task}\t1\tpending\t{repo}\tt-fixture\thermes\n')
    (bg / 'sample.rkey').write_text('sample-key')
    result = bg / 'r-sample-key.result'
    result.write_text('摘要：完成\n---細節---\nhttps://detail.example/two\n')
    db = base / 'state.db'
    with sqlite3.connect(db) as c:
        c.execute('CREATE TABLE messages(id INTEGER, session_id TEXT, role TEXT, content TEXT)')
        c.executemany('INSERT INTO messages VALUES(?,?,?,?)', [(1,'s','user','r-sample-key.result'), (2,'s','tool','測試通過 https://tool.example/three'), (3,'other','tool','https://other.example/four')])
    env = dict(os.environ, MYTHOS_DIR=str(repo), MYTHOS_WORKER_DB=str(db), CLAIMCHECK_LIB=str(base/'missing.js'))
    summary = base / 'summary'
    def check(text, rc=0, mode='--free-only', extra=None):
        summary.write_text(text)
        p = run([str(guard)] + ([mode] if mode else []) + [str(summary), 'bg-sample', str(repo)], env=dict(env, **(extra or {})))
        assert p.returncode == rc, (text, p.returncode, p.stdout, p.stderr)
        return json.loads(p.stdout)
    ok(not check('commit ' + sha)['blocked'], '真 sha 放行')
    ok(not check('commit ' + sha[:7])['blocked'], '短 sha 放行')
    ok(check('commit abcdef0', 3)['findings'][0]['kind'] == 'fabricated_commit', '假 sha 擋')
    for url in ('https://task.example/one', 'https://detail.example/two', 'https://tool.example/three'):
        ok(not check(url)['blocked'], '證據網址放行 ' + url)
    ok(not check('來源（https://tool.example/three）。')['blocked'], '網址中文標點放行')
    ok(check('https://other.example/four', 3)['blocked'], '別張 job 網址擋')
    ok(check('https://unknown.example/five', 3)['blocked'], '證據外網址擋')
    with sqlite3.connect(db) as c:
        c.execute("INSERT INTO messages VALUES(4,'ambiguous','user','r-sample-key.result')")
    out = check('https://unknown.example/five')
    ok(not out['evidence_matched'] and not out['blocked'] and out['evidence_reason'], '模糊 session 只記錄原因')
    with sqlite3.connect(db) as c:
        c.execute('DELETE FROM messages WHERE id=4')
    ok(check('測試通過', mode='--observe')['laya']['status'] == 'unavailable', '缺程式庫記 unavailable')
    # 假 cascade；真 checkClaims + runVerify，絕不呼叫正式 cascade。
    seen = []
    response = {'status': 503, 'delay': 0}
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            seen.append((self.path, dict(self.headers), json.loads(self.rfile.read(int(self.headers['Content-Length'])))))
            time.sleep(response['delay'])
            self.send_response(response['status'])
            self.end_headers()
            try:
                self.wfile.write(b'{}')
            except BrokenPipeError:
                pass
        def log_message(self, *args):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    lib = Path.home() / 'dev/jev-gate-mcp/plugin/lib/claimcheck.js'
    assert lib.is_file(), '離線驗收需安裝既有 claimcheck 程式庫'
    extra = {'CLAIMCHECK_LIB': str(lib), 'CLAIMCHECK_CASCADE_URL': f'http://127.0.0.1:{server.server_port}'}
    out = check('測試通過，功能已修復。', mode='', extra=extra)
    ok(out['laya']['status'] == 'undecided', 'cascade 503 undecided 且 exit 0')
    ok(bool(seen) and all(h.get('x-jev-mode') == 'laya-only' and h.get('x-jev-caller') == 'mythos-claimcheck' for _, h, _ in seen), '請求固定 laya-only 與 caller')
    ok(all(p == '/v1/systemone' and b.get('questions') for p, _, b in seen), '真 verify 接口送 typed questions')
    response['status'] = 200
    out = check('測試通過，功能已修復。', mode='--observe', extra=extra)
    ok(out['laya']['status'] == 'undecided', 'cascade 格式錯誤 undecided')
    response['delay'] = 4
    started = time.monotonic()
    out = check('測試通過，功能已修復。', mode='--observe', extra=extra)
    ok(out['laya']['status'] == 'undecided' and time.monotonic() - started < 3.8, 'cascade 三秒逾時 undecided')
    server.shutdown()
    server.server_close()
    out = check('測試通過，功能已修復。', mode='--observe', extra=extra)
    ok(out['laya']['status'] == 'undecided', 'cascade 無連線 undecided')
    ok(len(check('x' * 250)['summary']) == 200, 'ledger 摘要上限')
    # 真 dispatch-watch，沿用既有測試的隔離設定與工具 stub。
    prefix = (root / 'tests/test-watch-ask-permission.sh').read_text().split('# 摘要含請示句（')[0]
    prefix = prefix.replace('ROOT="$(cd "$(dirname "$0")/.." && pwd)"', 'ROOT="$TEST_ROOT"')
    prefix = prefix.replace('"$(dirname "$0")/lib-test-guard.sh"', '"$ROOT/tests/lib-test-guard.sh"')
    body = r'''
mkdir -p "$MYTHOS_DIR/logs"
export BRIEF_LINES_DIR="$TMP/alerts" MYTHOS_DELIVER=tg
printf '#!/bin/sh\ncat\n' > "$BRIEF_BIN"
export MYTHOS_WORKER_DB="$TMP/nonexistent.db" CLAIMCHECK_LIB="$TMP/nonexistent.js"
git init -q "$MYTHOS_DIR"
printf '/state/\n' > "$MYTHOS_DIR/.gitignore"
export CLAIM_GUARD_BIN="$TMP/broken"
printf '#!/bin/sh\nexit 42\n' > "$CLAIM_GUARD_BIN"; chmod +x "$CLAIM_GUARD_BIN"
row bg-open bg "$(date +%s)"
printf '摘要：完成修復\n---細節---\nx\n' > "$MYTHOS_DIR/state/bg/open.result"
agents open done
bash "$ROOT/bin/dispatch-watch"
[ "$(wc -l < "$TMP/tg.sent" | tr -d ' ')" = 1 ] || fail '壞掉應 fail-open 直發'
grep -q 'claim-guard fail-open rc=42' "$MYTHOS_DIR/logs/dispatch-watch.log" || fail '缺 fail-open log'
export CLAIM_GUARD_BIN="$ROOT/bin/claim-guard"
row bg-block bg "$(date +%s)"
printf '摘要：完成 commit abcdef0\n---細節---\nx\n' > "$MYTHOS_DIR/state/bg/block.result"
agents block done
bash "$ROOT/bin/dispatch-watch"
bash "$ROOT/bin/dispatch-watch"
[ "$(wc -l < "$TMP/tg.sent" | tr -d ' ')" = 1 ] || fail "exit 3 不可 TG 直發 $(cat "$MYTHOS_DIR/logs/dispatch-watch.log")"
[ "$(wc -l < "$BRIEF_LINES_DIR/mythos-claimguard.tsv" | tr -d ' ')" = 1 ] || fail '告警恰一行'
grep -q '這份結果裡有查不到的 commit 或網址，先別當真' "$MYTHOS_DIR/state/events.jsonl" || fail '缺白話警示'
grep -q 'event_id=bg-block-PASS' "$TMUX_LOG" || fail '未交 Router'
export MYTHOS_DELIVER=hermes
cat > "$TG_SEND_BIN" <<'JS'
import fs from 'node:fs';
let s=''; for await (const c of process.stdin) s+=c;
fs.appendFileSync(process.env.TMP+'/inbox', s);
JS
row bg-inbox bg "$(date +%s)"
printf '摘要：完成 commit abcdef0\n---細節---\nx\n' > "$MYTHOS_DIR/state/bg/inbox.result"
agents inbox done
bash "$ROOT/bin/dispatch-watch"
grep -q '先別當真；改由 Router 轉述' "$TMP/inbox" || fail 'Hermes 未交 Router 轉述'
! grep -q '^完成 commit' "$TMP/inbox" || fail 'Hermes 原摘要直發'
# 背景觀察須在投遞後啟動；即使觀察未完成，watch 也必須先返回。
export MYTHOS_DELIVER=tg CLAIM_GUARD_BIN="$TMP/observe-wrapper"
cat > "$TG_SEND_BIN" <<'JS'
import fs from 'node:fs';
for await (const c of process.stdin) {}
fs.writeFileSync(process.env.TMP+'/async-sent', 'sent');
JS
cat > "$CLAIM_GUARD_BIN" <<'WRAP'
#!/bin/bash
if [ "$1" = --observe ]; then
  [ -f "$TMP/async-sent" ] || exit 9
  touch "$TMP/observe-start"
  for n in {1..100}; do
    [ ! -f "$TMP/observe-release" ] || { touch "$TMP/observe-done"; exit 0; }
    sleep 0.05
  done
  exit 8
fi
exec "$TEST_ROOT/bin/claim-guard" "$@"
WRAP
chmod +x "$CLAIM_GUARD_BIN"
row bg-async bg "$(date +%s)"
printf '摘要：完成修復\n---細節---\nx\n' > "$MYTHOS_DIR/state/bg/async.result"
agents async done
bash "$ROOT/bin/dispatch-watch"
for n in {1..30}; do [ -f "$TMP/observe-start" ] && break; sleep 0.05; done
[ -f "$TMP/observe-start" ] && [ ! -f "$TMP/observe-done" ] || fail 'Laya 未在送出後背景跑'
touch "$TMP/observe-release"
for n in {1..30}; do [ -f "$TMP/observe-done" ] && break; sleep 0.05; done
[ -f "$TMP/observe-done" ] || fail '背景觀察未收尾'
echo 'PASS dispatch-watch fail-open／block／Router／單次告警／Hermes 收件匣／背景觀察'
'''
    script = base / 'watch.sh'
    script.write_text(prefix + body)
    sandbox = os.environ['MYTHOS_TEST_SANDBOX']
    integration_env = {k: v for k, v in os.environ.items() if not v.startswith(sandbox)}
    p = run(['bash', str(script)], env=dict(integration_env, TEST_ROOT=str(root)))
    assert p.returncode == 0, p.stdout + p.stderr
    print(p.stdout, end='')
print('CLAIM-GUARD PASS')
PY
