---
name: zh-cn-setup
description: 完成 Claude Code 中文在地化的首次增強安裝——把 spinner/介面中文化配置合併進 settings.json、偵測並同步 CC Switch 通用配置、提示重啟讓 CLI patch 生效。中文使用者安裝本外掛後如發現 spinner 動詞/提示仍是英文，或想完整啟用中文化，請使用本 skill。
allowed-tools: Bash(node:${CLAUDE_PLUGIN_ROOT}/skills/zh-cn-setup/scripts/setup.js:*), Bash(node:*skills/zh-cn-setup/scripts/setup.js*:*), Write, Read
---

# zh-cn-setup：中文在地化增強安裝

本 skill 是 `claude-code-zh-cn` 外掛的首次增強安裝入口。在使用者透過 `claude plugin marketplace add` + `claude plugin install` 裝好外掛後，執行本 skill 可補齊以下"裝外掛本身不會自動完成"的步驟。

## 何時使用

當使用者表達以下意圖時主動觸發：

- "spinner 還是英文" / "轉圈的文字沒翻譯"
- "怎麼完整啟用中文" / "安裝完後還要做什麼"
- 在 Windows / macOS / Linux 上剛裝好外掛，想確認中文化是否完整

## 執行步驟

執行跨平台安裝腳本（macOS / Linux / Windows 通用，需 Node.js）：

```bash
node "${CLAUDE_PLUGIN_ROOT}/skills/zh-cn-setup/scripts/setup.js"
```

腳本會自動完成：

1. **合併 spinner 中文化配置**到 `~/.claude/settings.json`（從外掛內建的 verbs/tips 資料構建，只補齊缺失項，不覆蓋使用者已有配置；帶備份 + 原子寫）
2. **偵測 CC Switch**：若偵測到 CC Switch 的通用配置缺少中文設定，腳本會輸出需要使用者確認的提示——因為是互動式安裝，**請把腳本輸出的指令原文轉達給使用者**，讓使用者決定是否授權同步
3. **報告 patch 狀態**並提示是否需要重啟

## 重要約束

- **不要**在 skill 裡呼叫 `claude plugin install` / `claude plugin update`：外掛本體的安裝/更新由使用者手動或 Claude plugin manager 負責，避免"外掛裝自己/更新自己"的迴圈
- **CLI patch（npm cli.js / native exe）由 session-start hook 自動維護**，不在本 skill 內手動 patch。native exe 更新後需要使用者關閉所有 Claude Code 視窗再重開，腳本會提示
- 腳本所有寫操作都帶備份和失敗回滾，不會讓機器配置損壞

## 給使用者的最終提示

腳本跑完後，根據其輸出告訴使用者：

- 如果提示"請重啟 Claude Code"：說明 CLI patch 已由 hook 處理，重啟後生效
- 如果提示 CC Switch 同步：把腳本給出的手動步驟或授權命令轉給使用者
