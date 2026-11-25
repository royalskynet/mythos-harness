#!/usr/bin/env bash
# Router 派工的子代理要有自己的 fallback 鏈：pinned 子代理（delegation.provider/model 明寫）
# 不繼承頂層 fallback_providers（hermes scoped_fallback_chain pinned → 不用 parent 鏈），
# 鏈要寫在 delegation 底下。11-25 00:23 實例：OpenCode Go 月配額 429，兩個子代理各 1.2 秒陣亡、
# 一棒都沒走。
#
# E2E 驗屍補充（同晚 /tmp/hermes-e2e 實跑）：
# - 429 會把該 provider 的憑證標成 exhausted（auth.json credential_pool），
#   _candidate_pool_exhausted 讓同 provider 的後續棒全被跳過——Go 月配額死時，
#   *-free 棒也走不了，只有非 Go 腿活得下來。所以鏈必須有一棒非 opencode-go。
# - provider: omniroute 這種自訂名要出現在 custom_providers 才 bind 得到，
#   否則 "provider not configured" 整棒作廢。
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0 n=0
for f in profiles/mythos/config.yaml; do
  n=$((n+1))
  python3 - "$f" <<'PY' || fail=1
import re
import sys


def _mini_load(text):
    # 最小 YAML 子集：本 repo config 只用 map、scalar list、map list（CI 乾淨環境沒有 PyYAML）
    toks = []
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        cut = raw.find(" #")
        line = (raw[:cut] if cut != -1 else raw).rstrip()
        toks.append((len(line) - len(line.lstrip(" ")), line.strip()))
    pos = [0]

    def scalar(v):
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            return v[1:-1]
        if v in ("true", "yes"):
            return True
        if v in ("false", "no"):
            return False
        if v in ("", "null", "~"):
            return None
        try:
            return int(v)
        except ValueError:
            try:
                return float(v)
            except ValueError:
                return v

    def parse(min_indent):
        if pos[0] >= len(toks) or toks[pos[0]][0] < min_indent:
            return None
        ind0, c0 = toks[pos[0]]
        if c0.startswith("- "):
            out = []
            while pos[0] < len(toks):
                ind, c = toks[pos[0]]
                if ind != ind0 or not c.startswith("- "):
                    break
                pos[0] += 1
                item = c[2:]
                if re.match(r"^[^\s:]+:\s*", item):
                    k, _, v = item.partition(":")
                    d = {k.strip(): scalar(v)}
                    sub = parse(ind0 + 2)
                    if isinstance(sub, dict):
                        d.update(sub)
                    out.append(d)
                else:
                    out.append(scalar(item))
            return out
        out = {}
        while pos[0] < len(toks):
            ind, c = toks[pos[0]]
            if ind != ind0 or c.startswith("- ") or ":" not in c:
                break
            k, _, v = c.partition(":")
            pos[0] += 1
            out[k.strip()] = scalar(v) if v.strip() else parse(ind0 + 1)
        return out

    r = parse(0) or {}
    assert pos[0] == len(toks), "mini yaml: 未吃完（不支援的語法）"
    return r


try:
    import yaml
except ImportError:
    yaml = None
# 自測：block scalar 等未支援語法必須丟例外，不能靜默吃一半
try:
    _mini_load("note: |\n  block scalar\n")
except AssertionError:
    pass
else:
    print("FAIL: 迷你 parser 吃下 block scalar 沒丟例外")
    sys.exit(1)
cfg = yaml.safe_load(open(sys.argv[1])) if yaml else _mini_load(open(sys.argv[1]).read())
f = sys.argv[1]
named = {p.get("name") for p in (cfg.get("custom_providers") or []) if isinstance(p, dict)}
core = {"opencode-go", "openrouter", "anthropic", "openai", "google", "copilot", "nous", "ollama"}

def check_chain(chain, where):
    ok = True
    if not chain:
        print(f"FAIL: {f} {where} 沒有 fallback 鏈"); return False
    go_free = [e for e in chain if e.get("provider") == "opencode-go" and str(e.get("model","")).endswith("-free")]
    non_go = [e for e in chain if e.get("provider") not in ("opencode-go", None)]
    if not go_free:
        print(f"FAIL: {f} {where} 沒有 opencode-go *-free 棒"); ok = False
    if not non_go:
        print(f"FAIL: {f} {where} 全是 opencode-go：429 毒憑證池時全鏈同死"); ok = False
    seen = set()
    for e in chain:
        prov = e.get("provider")
        k = (prov, e.get("model"), str(e.get("base_url","")).rstrip("/"))
        if k in seen:
            print(f"FAIL: {f} {where} 重複 {k}"); ok = False
        seen.add(k)
        if prov and prov not in core and prov not in named:
            print(f"FAIL: {f} {where} 的 {prov} 沒在 custom_providers 註冊（bind 不到 → 棒作廢）"); ok = False
        if prov in named and prov in core:
            print(f"FAIL: {f} {where} 的 {prov} 撞名 core provider"); ok = False
    return ok

ok = True
ok &= check_chain((cfg.get("delegation") or {}).get("fallback_providers"), "delegation.fallback_providers")
primary = str((cfg.get("delegation") or {}).get("model") or "")
if not primary.endswith("-free"):
    print(f"FAIL: {f} delegation.model 是 {primary}（要 *-free：配額死時子代理先白撞 429、再落到慢的 oo 腿）"); ok = False

ok &= check_chain(cfg.get("fallback_providers"), "頂層 fallback_providers")
sys.exit(0 if ok else 1)
PY
done
# mythos-worker 也要：它的 fallback 照樣引用 omniroute
for f in profiles/mythos-worker/config.yaml; do
  n=$((n+1))
  python3 - "$f" <<'PY' || fail=1
import re
import sys


def _mini_load(text):
    # 最小 YAML 子集：本 repo config 只用 map、scalar list、map list（CI 乾淨環境沒有 PyYAML）
    toks = []
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        cut = raw.find(" #")
        line = (raw[:cut] if cut != -1 else raw).rstrip()
        toks.append((len(line) - len(line.lstrip(" ")), line.strip()))
    pos = [0]

    def scalar(v):
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            return v[1:-1]
        if v in ("true", "yes"):
            return True
        if v in ("false", "no"):
            return False
        if v in ("", "null", "~"):
            return None
        try:
            return int(v)
        except ValueError:
            try:
                return float(v)
            except ValueError:
                return v

    def parse(min_indent):
        if pos[0] >= len(toks) or toks[pos[0]][0] < min_indent:
            return None
        ind0, c0 = toks[pos[0]]
        if c0.startswith("- "):
            out = []
            while pos[0] < len(toks):
                ind, c = toks[pos[0]]
                if ind != ind0 or not c.startswith("- "):
                    break
                pos[0] += 1
                item = c[2:]
                if re.match(r"^[^\s:]+:\s*", item):
                    k, _, v = item.partition(":")
                    d = {k.strip(): scalar(v)}
                    sub = parse(ind0 + 2)
                    if isinstance(sub, dict):
                        d.update(sub)
                    out.append(d)
                else:
                    out.append(scalar(item))
            return out
        out = {}
        while pos[0] < len(toks):
            ind, c = toks[pos[0]]
            if ind != ind0 or c.startswith("- ") or ":" not in c:
                break
            k, _, v = c.partition(":")
            pos[0] += 1
            out[k.strip()] = scalar(v) if v.strip() else parse(ind0 + 1)
        return out

    r = parse(0) or {}
    assert pos[0] == len(toks), "mini yaml: 未吃完（不支援的語法）"
    return r


try:
    import yaml
except ImportError:
    yaml = None
# 自測：block scalar 等未支援語法必須丟例外，不能靜默吃一半
try:
    _mini_load("note: |\n  block scalar\n")
except AssertionError:
    pass
else:
    print("FAIL: 迷你 parser 吃下 block scalar 沒丟例外")
    sys.exit(1)
cfg = yaml.safe_load(open(sys.argv[1])) if yaml else _mini_load(open(sys.argv[1]).read())
f = sys.argv[1]
named = {p.get("name") for p in (cfg.get("custom_providers") or []) if isinstance(p, dict)}
chain = cfg.get("fallback_providers") or []
missing = [e.get("provider") for e in chain
           if e.get("provider") not in ("opencode-go","openrouter","anthropic","openai","google","copilot","nous","ollama")
           and e.get("provider") not in named]
if missing:
    print(f"FAIL: {f} fallback 引用未註冊 provider：{missing}"); sys.exit(1)
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
