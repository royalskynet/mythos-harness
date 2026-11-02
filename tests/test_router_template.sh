#!/usr/bin/env bash
# 驗收：router/ 範本真的組出「Sonnet 聊天＋Opus advisor＋PreToolUse 派工閘」，照 router/start.sh 啟動。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
S="$ROOT/router/settings.json"

# 1. 模型分層
[ "$(jq -r .model "$S")" = claude-sonnet-5-5 ] || fail "Router 應是 Sonnet"
[ "$(jq -r .advisorModel "$S")" = claude-opus-5-5 ] || fail "advisor 應是 Opus"

# 2. settings 裡的 hook 指令原樣執行：mid 擋寫檔、easy 放行
hook="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$S")"
printf '#!/bin/sh\nprintf "%%s\\n" "$TRIAGE_OUT"\n' > "$TMP/triage"; chmod +x "$TMP/triage"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"改一下 foo"}}' > "$TMP/t.jsonl"
payload='{"tool_name":"Write","tool_input":{"file_path":"/opt/elsewhere/foo.js"},"transcript_path":"'"$TMP/t.jsonl"'","session_id":"s"}'
call() { printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$ROOT" MYTHOS_DIR="$TMP/bot" DISPATCH_GATE_TRIAGE="$TMP/triage" TRIAGE_OUT="$1" sh -c "$hook"; }
mkdir -p "$TMP/bot/state"
call mid | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null || fail "mid 應擋 Router 親手寫檔"
rm -f "$TMP/bot/state/dispatch-gate.json"
[ -z "$(call easy)" ] || fail "easy 應放行"

# 3. ROUTER.md 講到的指令都真的在
for c in dispatch dispatch-watch review-judge dispatch-retry dispatch-cancel dispatch-gate.mjs; do
  grep -q "bin/$c" "$ROOT/router/ROUTER.md" || fail "ROUTER.md 沒提 bin/$c"
  [ -e "$ROOT/bin/$c" ] || fail "bin/$c 不存在"
done
grep -q advisor "$ROOT/router/ROUTER.md" || fail "ROUTER.md 沒寫何時叫 advisor"

# 4. start.sh 帶對參數、打對 tmux socket
mkdir -p "$TMP/path"
printf '#!/bin/sh\necho "$*" >> "%s/tmux.log"\n[ "$3" = has-session ] && exit 1\nexit 0\n' "$TMP" > "$TMP/path/tmux"; chmod +x "$TMP/path/tmux"
PATH="$TMP/path:$PATH" bash "$ROOT/router/start.sh" >/dev/null
log="$(cat "$TMP/tmux.log")"
case "$log" in *"-L mythos new-session"*) ;; *) fail "start.sh 沒用 tmux -L mythos：$log" ;; esac
for a in "--settings" "router/settings.json" "--append-system-prompt-file" "router/ROUTER.md" "--channels" "plugin:telegram@claude-plugins-official"; do
  case "$log" in *"$a"*) ;; *) fail "start.sh 少了 $a：$log" ;; esac
done
echo "ROUTER-TEMPLATE PASS"
