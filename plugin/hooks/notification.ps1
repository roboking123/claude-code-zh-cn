#!/usr/bin/env pwsh
# notification hook for claude-code-zh-cn (Windows PowerShell 版本)
# 翻譯常見通知訊息為中文

$rawInput = [Console]::In.ReadToEnd()

$message = ""
try {
    $data = $rawInput | ConvertFrom-Json
    $message = [string]$data.message
} catch {}

$translated = ""
switch -Wildcard ($message) {
    "*Rate limited*"        { $translated = "請求頻率受限，請稍後再試" }
    "*Token limit reached*"  { $translated = "Token 用量已達上限" }
    "*Session expired*"      { $translated = "工作階段已過期" }
    "*Context window*"       { $translated = "上下文視窗即將用盡，建議使用 /compact 壓縮" }
    "*Usage limit*"          { $translated = "使用額度已達上限" }
    "*Auto-compact*"         { $translated = "正在自動壓縮對話歷史..." }
}

if ($translated) {
    $result = @{
        hookSpecificOutput = @{
            hookEventName    = "Notification"
            additionalContext = "通知翻譯：$translated"
        }
    }
    $result | ConvertTo-Json -Compress
} else {
    Write-Output "{}"
}
