#!/usr/bin/env node

"use strict";

const fs = require("node:fs");

const translations = [
  ["Rate limited", "請求頻率受限，請稍後再試"],
  ["Token limit reached", "Token 用量已達上限"],
  ["Session expired", "工作階段已過期"],
  ["Context window", "上下文視窗即將用盡，建議使用 /compact 壓縮"],
  ["Usage limit", "使用額度已達上限"],
  ["Auto-compact", "正在自動壓縮對話歷史..."],
];

function main() {
  let message = "";
  try {
    message = String(JSON.parse(fs.readFileSync(0, "utf8") || "{}").message || "");
  } catch {}

  const match = translations.find(([source]) => message.includes(source));
  if (!match) {
    process.stdout.write("{}\n");
    return;
  }

  process.stdout.write(
    `${JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "Notification",
        additionalContext: `通知翻譯：${match[1]}`,
      },
    })}\n`
  );
}

main();
