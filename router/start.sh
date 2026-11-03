#!/usr/bin/env bash
# 啟動 Router：Sonnet 聊天＋Opus advisor＋派工閘，跑在 tmux（Claude Code 要 TTY），Telegram 當對話通道。
# 先在 Claude Code 裡跑過一次：/plugin install telegram@claude-plugins-official 與 /telegram:configure <bot token>
# 不要 Telegram 就設 CHANNELS= 空字串，直接在 tmux 裡聊。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SESSION=mythos  # dispatch-watch／idle-reset 固定打 tmux -L mythos -t mythos
CHANNELS="${CHANNELS-plugin:telegram@claude-plugins-official}"
args=(--settings "$ROOT/router/settings.json" --append-system-prompt-file "$ROOT/router/ROUTER.md")
[ -n "$CHANNELS" ] && args+=(--channels "$CHANNELS")
mkdir -p "$ROOT/.claude/agents" && ln -sf "$ROOT/router/agents/dispatcher.md" "$ROOT/.claude/agents/dispatcher.md"  # Router 唯一的手
tmux -L mythos has-session -t "$SESSION" 2>/dev/null && { echo "tmux session $SESSION 已在跑：tmux -L mythos attach -t $SESSION"; exit 0; }
tmux -L mythos new-session -d -s "$SESSION" -c "$ROOT" "claude $(printf '%q ' "${args[@]}")"
echo "已啟動：tmux -L mythos attach -t $SESSION"
