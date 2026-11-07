#!/usr/bin/env bash
# quick 的暫存 opencode 設定：引用檔案的 provider 與 mcp 要拿掉，其餘保留（沙箱擋憑證目錄後 opencode 才起得來）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/cfg/opencode"
printf '%s' '{"model":"m","mcp":{"x":{}},"provider":{"keyed":{"options":{"apiKey":"{file:/nope/k.txt}"}},"free":{"models":{"a":{}}}}}' > "$TMP/cfg/opencode/opencode.json"
XDG_CONFIG_HOME="$TMP/cfg" python3 - "$ROOT/bin/quick" <<'PY'
import json, os, runpy, sys
env = runpy.run_path(sys.argv[1])["clean_config_env"]()
assert env, "沒有產生暫存設定"
cfg = json.load(open(os.path.join(env["XDG_CONFIG_HOME"], "opencode", "opencode.json")))
assert "mcp" not in cfg, "mcp 沒拿掉"
assert list(cfg["provider"]) == ["free"], "provider 過濾錯：%s" % list(cfg["provider"])
assert cfg["model"] == "m", "其他設定被動到"
print("PASS quick 暫存設定去掉引用檔案的 provider 與 mcp")
PY
