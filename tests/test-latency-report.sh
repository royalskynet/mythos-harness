#!/usr/bin/env bash
# 回覆延遲量測（C2）驗收：假 transcript，延遲 5s／30s／120s 各一筆＋1 筆沒回。
# （第 4 則 user 之後沒有 reply＝沒回；n=4 是 3 筆有回＋1 筆沒回）
# 百分位取最近秩，只在有回覆的樣本上排（no-reply 不進排序）：p50 = 第 ceil(0.5k) 名、p90 = 第 ceil(0.9k) 名
# （k=3 → 第 2、3 名＝30、120）。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/latency-report-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
D="$TMP/projects"; mkdir -p "$D"
fail() { echo "FAIL: $*" >&2; exit 1; }

# 一行 user／一行 assistant；timestamp 用 ISO8601。基準取「現在 − 1 小時」：
# latency-report 只收 --days 內的行，寫死日期的話過幾天測試就自己壞掉
# 用 jq -c 產 JSON：手寫跳脫太容易錯
B=$(( $(date +%s) - 3600 ))
ts() { date -u -r $(( B + $1 )) +%Y-%m-%dT%H:%M:%SZ; }
CH='<channel source="telegram" chat_id="1">hi'
user() { jq -cn --arg t "$(ts "$1")" --arg c "$CH" '{type:"user",timestamp:$t,message:{content:$c}}'; }
reply() { jq -cn --arg t "$(ts "$1")" '{type:"assistant",timestamp:$t,message:{content:[{type:"tool_use",id:"t",name:"mcp__telegram__reply",input:{}}]}}'; }
other_tool() { jq -cn --arg t "$(ts "$1")" '{type:"assistant",timestamp:$t,message:{content:[{type:"tool_use",id:"t2",name:"Bash",input:{}}]}}'; }

{
  user 0;    other_tool 2; reply 5      # 5s
  user 60;   reply 90                   # 30s
  user 120;  reply 240                  # 120s
  user 300                              # 沒回（之後沒有 reply）
} > "$D/session.jsonl"

out="$(MYTHOS_TRANSCRIPT_DIR="$D" bash "$ROOT/bin/latency-report" --days 7)"
[ "$out" = "$(printf '4\t30\t120\t120\t1\t1')" ] || fail "TSV 不對：${out}（預期 n=4 p50=30 p90=120 max=120 over60=1 no_reply=1）"

j="$(MYTHOS_TRANSCRIPT_DIR="$D" bash "$ROOT/bin/latency-report" --json)"
[ "$j" = '{"n":4,"p50_s":30,"p90_s":120,"max_s":120,"over60":1,"no_reply":1}' ] || fail "JSON 不對：${j}"

# --days 0 不合法
MYTHOS_TRANSCRIPT_DIR="$D" bash "$ROOT/bin/latency-report" --days 0 >/dev/null 2>&1 && fail '--days 0 沒被擋'

echo 'LATENCY-REPORT PASS'
