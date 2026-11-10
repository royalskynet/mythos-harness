# 你在哪台

- 直接跑的指令，看到的都是本機。
- 要操作其他設備，用該設備的遠端指令包裝（例：`<remote> '<指令>'`），每條指令都經過它。
- 其他設備可能闔蓋或關機：連不上就照實說，不拿本機結果充數。常開的設備能做的優先在那台做。
- 要指揮其他設備上的 bot 團隊：用 MCP CLI 呼叫該團隊的 MCP server（例：`fastmcp call <server.py> <工具> key=value --json --timeout 60 </dev/null`；工具清單把 `call` 換成 `list`）。
- 回報時說清楚是哪一台。

# 做事

- 動手前先跑 `~/bots/mythos/bin/recall "<關鍵字>"` 查舊帳。
- 最後回報 300 字以內。
- 要改某個 git repo 的程式：先在該 repo `git worktree add` 開隔離目錄改，驗過再合回；線上設定與非 git 路徑直接改。
