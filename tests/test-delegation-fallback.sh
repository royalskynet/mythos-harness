#!/usr/bin/env bash
# Router 派工的子代理要有自己的 fallback 鏈：pinned 子代理（delegation.provider/model 明寫）
# 不繼承頂層 fallback_providers（hermes scoped_fallback_chain pinned → 不用 parent 鏈），
# 鏈要寫在 delegation 底下。11-25 00:23 實例：OpenCode Go 月配額 429，兩個子代理各 1.2 秒陣亡、
# 一棒都沒走。鏈至少要有一棒 *-free（不吃月配額）與一棒非 opencode-go（Go 全掛時的活路）。
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0 n=0
for f in profiles/mythos/config.yaml; do
  n=$((n+1))
  python3 - "$f" <<'PY' || fail=1
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
chain = ((cfg.get("delegation") or {}).get("fallback_providers")) or []
f = sys.argv[1]
if not chain:
    print(f"FAIL: {f} delegation.fallback_providers 沒設：pinned 子代理沒有鏈，主模型 429 直接死"); sys.exit(1)
go_free = [e for e in chain if e.get("provider") == "opencode-go" and str(e.get("model","")).endswith("-free")]
non_go = [e for e in chain if e.get("provider") != "opencode-go"]
if not go_free:
    print(f"FAIL: {f} delegation 鏈沒有 opencode-go *-free 棒（月配額 429 時全鏈同死）"); sys.exit(1)
if not non_go:
    print(f"FAIL: {f} delegation 鏈全是 opencode-go（Go 全掛時沒有活路）"); sys.exit(1)
# 同 provider+model 重複會被正規化去重，等於少一棒
seen = set()
for e in chain:
    k = (e.get("provider"), e.get("model"), str(e.get("base_url","")).rstrip("/"))
    if k in seen:
        print(f"FAIL: {f} delegation 鏈重複 {k}"); sys.exit(1)
    seen.add(k)
PY
done
# 行為層：router-guard 的 ALLOWED 白名單是純聊天的機械邊界（派工＋查記憶＋memory，其他全擋）
python3 - <<'PY' || fail=1
import sys; sys.path.insert(0, "profiles/mythos/plugins/router-guard")
import importlib.util
spec = importlib.util.spec_from_file_location("guard", "profiles/mythos/plugins/router-guard/__init__.py")
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
assert g.ALLOWED == frozenset({"delegate_task", "mythos_recall", "memory"}), f"ALLOWED 變了：{g.ALLOWED}"
for t in ("terminal", "read_file", "write_file", "patch", "process_manage", "mcp__browse__execute"):
    r = g._on_pre_tool_call(tool_name=t, args={}, session_id="router-test")
    assert r and r.get("action") == "block", f"應 block：{t}"
r = g._on_pre_tool_call(tool_name="delegate_task", args={"goal": "g"}, session_id="router-test")
assert r and r.get("action") == "modify" and r["args"].get("background") is True, "派工要強制 background"
PY
[ "$n" -gt 0 ] || { echo "FAIL: 沒找到任何 profile 設定"; exit 1; }
[ "$fail" = 0 ] && echo "DELEGATION-FALLBACK PASS ($n)"
exit "$fail"
