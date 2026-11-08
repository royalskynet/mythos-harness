#!/usr/bin/env bash
# bin/hermes-contract 要真的會叫：plugin 用了 Hermes 沒有的掛鉤、線上 profile 跟 repo 不一致，都要 FAIL。
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cp -R "$REPO/profiles" "$T/dist"
# 假的線上 profile：照 repo 正本鋪，只放契約會比的檔
mkdir -p "$T/live"; cp -R "$REPO/profiles/mythos" "$REPO/profiles/mythos-worker" "$T/live/"
mkdir -p "$T/live/mythos-worker/plugins"; ln -s /nonexistent "$T/live/mythos-worker/plugins/claude-mem"
run() { MYTHOS_DIST_DIR="$T/dist" HERMES_PROFILES_ROOT="$T/live" "$REPO/bin/hermes-contract" 2>&1; }
ok=1

out="$(run)"; echo "$out" | grep -q '^FAIL 漂移' && { echo "對照組不該有漂移：$out"; ok=0; }

printf '\n# test\n' >> "$T/live/mythos/SOUL.md"
out="$(run)"; echo "$out" | grep -q '^FAIL 漂移 mythos/SOUL.md' || { echo "改線上 SOUL 沒抓到：$out"; ok=0; }
cp "$REPO/profiles/mythos/SOUL.md" "$T/live/mythos/SOUL.md"

printf '\ndef _x(ctx):\n    ctx.register_hook("no_such_hook_xyz", None)\n' >> "$T/dist/mythos/plugins/router-guard/__init__.py"
out="$(run)"; echo "$out" | grep -q 'no_such_hook_xyz' || { echo "假掛鉤沒抓到：$out"; ok=0; }

rm "$T/live/mythos-worker/plugins/claude-mem"
out="$(run)"; echo "$out" | grep -q 'claude-mem symlink' || { echo "symlink 消失沒抓到：$out"; ok=0; }

# 入站 async/skip 契約獨立用假上游原始碼驗證；其餘缺介面錯誤不影響這兩項判斷。
mkdir -p "$T/upstream/hermes_cli" "$T/upstream/gateway"
printf 'class Manager:\n async def ainvoke_hook(self):\n  if inspect.isawaitable(ret):\n   ret = await ret\n' > "$T/upstream/hermes_cli/plugins_dispatch.py"
printf 'async def inbound():\n _hook_results = await _ainvoke_hook("pre_gateway_dispatch")\n for result in _hook_results:\n  _action = result.get("action")\n  if _action == "skip":\n   return None\n' > "$T/upstream/gateway/run_inbound_hooks.py"
source_run() { HERMES_AGENT_ROOT="$T/upstream" run; }
out="$(source_run)"
echo "$out" | grep -Eq '^FAIL inbound-(await|skip)' && { echo "有效入站契約誤報：$out"; ok=0; }
sed 's/ret = await ret/ret = ret/' "$T/upstream/hermes_cli/plugins_dispatch.py" > "$T/no-await"
cp "$T/upstream/hermes_cli/plugins_dispatch.py" "$T/await-ok"
cp "$T/no-await" "$T/upstream/hermes_cli/plugins_dispatch.py"
out="$(source_run)"
echo "$out" | grep -q '^FAIL inbound-await' || { echo "移除 await 沒抓到：$out"; ok=0; }
cp "$T/await-ok" "$T/upstream/hermes_cli/plugins_dispatch.py"
sed 's/"skip"/"other"/' "$T/upstream/gateway/run_inbound_hooks.py" > "$T/no-skip"
cp "$T/no-skip" "$T/upstream/gateway/run_inbound_hooks.py"
out="$(source_run)"
echo "$out" | grep -q '^FAIL inbound-skip' || { echo "移除 skip 沒抓到：$out"; ok=0; }

[ "$ok" = 1 ] && echo PASS || { echo FAIL; exit 1; }
