#!/usr/bin/env node

// plugin/skills/zh-cn-setup/scripts/setup.js
//
// 跨平台（macOS / Linux / Windows）首次增強安裝腳本。
// 由 zh-cn-setup skill 呼叫，也可被使用者手動執行：
//   node ~/.claude/plugins/.../skills/zh-cn-setup/scripts/setup.js
//
// 職責（只做"裝外掛本身不會自動完成"的步驟）：
//   1. 從外掛內建 verbs/tips/settings-overlay 構建 overlay，合併進 ~/.claude/settings.json
//      （只補齊缺失項，並遷移廢棄的 spinnerVerbs 陣列；帶備份 + 原子寫）
//   2. 偵測 CC Switch 通用配置，必要時引導使用者授權同步（非互動時只輸出手動步驟）
//   3. 報告 patch 狀態，提示是否需要重啟
//
// 不做的事（避免迴圈依賴 / 重複維護）：
//   - 不調 claude plugin install/update（外掛本體由使用者或 plugin manager 管）
//   - 不手動 CLI patch（由 session-start hook 自動維護）

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { spawnSync } = require("node:child_process");

const {
  buildOverlay,
  fillMissingKeys,
  writeSettings,
  resolvePluginRoot,
} = require(path.join(__dirname, "..", "..", "..", "scripts", "build-overlay.js"));

function homeDir() {
  return process.env.HOME || process.env.USERPROFILE || os.homedir();
}

function settingsFile() {
  return path.join(homeDir(), ".claude", "settings.json");
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
  } catch {
    return fallback;
  }
}

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function spinnerVerbCount(value) {
  if (Array.isArray(value)) return value.length;
  return isPlainObject(value) && Array.isArray(value.verbs) ? value.verbs.length : 0;
}

function backupSettings(settingsPath) {
  try {
    const stamp = new Date()
      .toISOString()
      .replace(/[-:]/g, "")
      .replace(/\..+/, "")
      .replace("T", "");
    const backup = `${settingsPath}.zh-cn-backup.${stamp}`;
    if (fs.existsSync(settingsPath)) {
      fs.copyFileSync(settingsPath, backup);
      return backup;
    }
  } catch {
    // 備份失敗不阻塞，但返回 null
  }
  return null;
}

// ---- CC Switch 同步 ----

function ccSwitchDbPath() {
  return path.join(homeDir(), ".cc-switch", "cc-switch.db");
}

function sqlite3Available() {
  const result = spawnSync("sqlite3", ["--version"], { encoding: "utf8", windowsHide: true });
  return result.status === 0;
}

function ccSwitchReadCommonConfig(dbFile) {
  const result = spawnSync("sqlite3", [dbFile, "select value from settings where key='common_config_claude';"], {
    encoding: "utf8",
    windowsHide: true,
  });
  if (result.status !== 0) return null;
  const raw = (result.stdout || "").trim();
  return raw ? raw : "";
}

function ccSwitchConfigStatus(currentRaw, overlay) {
  // 與 install.ps1 JS_CCSWITCH_STATUS 同款判定
  const current = (() => {
    try {
      const v = JSON.parse((currentRaw || "").replace(/^\uFEFF/, ""));
      return isPlainObject(v) ? v : null;
    } catch {
      return null;
    }
  })();

  if (!current) return "invalid";

  const verbCount = spinnerVerbCount(current.spinnerVerbs);
  const tipCount = isPlainObject(current.spinnerTipsOverride) && Array.isArray(current.spinnerTipsOverride.tips)
    ? current.spinnerTipsOverride.tips.length
    : 0;

  const ok =
    current.language === "Chinese" &&
    current.spinnerTipsEnabled === true &&
    verbCount >= 100 &&
    tipCount >= 40;
  return ok ? "ok" : "needs-sync";
}

function syncCcSwitch(dbFile, overlay) {
  // 備份 → 合併 → 寫入 common_config_claude（事務）
  const stamp = new Date()
    .toISOString()
    .replace(/[-:]/g, "")
    .replace(/\..+/, "")
    .replace("T", "");
  const backup = `${dbFile}.zh-cn-backup.${stamp}`;
  try {
    fs.copyFileSync(dbFile, backup);
  } catch {
    return { ok: false, reason: "無法備份資料庫" };
  }

  const mergedJson = JSON.stringify(overlay, null, 2);
  // 用 hex 繫結參數避免引號轉義地獄：把合併後的 JSON 寫到臨時檔案，用 readfile() 讀入
  const mergedFile = path.join(os.tmpdir(), `cczh-ccswitch-merged-${process.pid}.json`);
  try {
    fs.writeFileSync(mergedFile, mergedJson);
    const escaped = mergedFile.replace(/'/g, "''");
    const sql = `begin immediate; insert or replace into settings(key,value) values('common_config_claude', CAST(readfile('${escaped}') AS TEXT)); delete from settings where key='common_config_claude_cleared'; commit;`;
    const result = spawnSync("sqlite3", [dbFile, sql], { encoding: "utf8", windowsHide: true });
    if (result.status !== 0) {
      return { ok: false, reason: "寫入失敗", backup };
    }
    return { ok: true, backup };
  } finally {
    try {
      fs.unlinkSync(mergedFile);
    } catch {
      // ignore
    }
  }
}

// ---- patch 狀態報告 ----

function reportPatchStatus(pluginRoot) {
  // session-start hook 把 patch marker 寫在 STATE_ROOT/.patched-version
  // 這裡只做只讀提示，不手動 patch
  const stateRoot = process.env.CLAUDE_PLUGIN_DATA || process.env.CLAUDE_PLUGIN_ROOT || pluginRoot;
  const markerFile = path.join(stateRoot, ".patched-version");
  const marker = fs.existsSync(markerFile) ? fs.readFileSync(markerFile, "utf8").trim() : "";

  const lines = [];
  if (marker) {
    lines.push(`✓ 已偵測到 CLI patch 標記：${marker.split("|")[0]}`);
    lines.push("  （CLI patch 由 session-start hook 自動維護；Claude Code 更新後會自動重新 patch）");
  } else {
    lines.push("ℹ 暫未偵測到 CLI patch 標記。這通常表示：");
    lines.push("  - 目前 Claude Code 版本暫不在已驗證視窗內（會走 provisional 本機自檢），或");
    lines.push("  - patch 將在下次工作階段啟動時由 hook 自動嘗試");
  }
  lines.push("");
  lines.push("如介面仍為英文，請完全離開所有 Claude Code 視窗後重新開啟（讓 hook 重新 patch）。");
  return lines.join("\n");
}

// ---- 主流程 ----

function main() {
  const pluginRoot = resolvePluginRoot();
  const settingsPath = settingsFile();

  console.log("claude-code-zh-cn 增強安裝\n");

  // 1. 合併 settings
  const overlay = buildOverlay(pluginRoot);
  const verbCount = spinnerVerbCount(overlay.spinnerVerbs);
  const tipCount = overlay.spinnerTipsOverride?.tips?.length || 0;
  console.log(`已從外掛內建資料構建 overlay：${verbCount} 個動詞、${tipCount} 條提示`);

  fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
  const current = isPlainObject(readJson(settingsPath, null)) ? readJson(settingsPath, {}) : {};
  const { changed, merged } = fillMissingKeys(settingsPath, overlay);

  if (changed) {
    const backup = backupSettings(settingsPath);
    if (backup) console.log(`已備份 settings.json → ${backup}`);
    writeSettings(settingsPath, merged);
    console.log("✓ 已補齊 settings.json 中缺失的中文配置（未覆蓋你已有的設定）");
  } else {
    console.log("✓ settings.json 已包含完整中文配置，無需修改");
  }

  // 2. CC Switch 同步
  const dbFile = ccSwitchDbPath();
  if (fs.existsSync(dbFile)) {
    if (!sqlite3Available()) {
      console.log("\n! 偵測到 CC Switch，但系統未安裝 sqlite3，無法自動同步通用配置。");
      console.log("  請手動在 CC Switch 的 Claude 通用配置里加入 language=Chinese、spinnerTipsEnabled=true 等。");
    } else {
      const currentRaw = ccSwitchReadCommonConfig(dbFile);
      if (currentRaw === null) {
        console.log("\n! 偵測到 CC Switch，但無法讀取通用配置表，已跳過自動同步。");
      } else {
        const status = ccSwitchConfigStatus(currentRaw, overlay);
        if (status === "ok") {
          console.log("\n✓ CC Switch 通用配置已是最新，無需同步");
        } else if (status === "invalid") {
          console.log("\n! 偵測到 CC Switch，但通用配置不是有效 JSON，已跳過自動同步。");
        } else {
          // needs-sync
          const choice = process.env.ZH_CN_CCSWITCH_SYNC;
          if (choice === "1" || choice === "true" || choice === "yes") {
            const result = syncCcSwitch(dbFile, overlay);
            if (result.ok) {
              console.log("\n✓ 已在授權後同步 CC Switch 通用配置");
              if (result.backup) console.log(`  備份 → ${result.backup}`);
            } else {
              console.log(`\n! CC Switch 同步失敗：${result.reason || "未知錯誤"}`);
              if (result.backup) console.log(`  同步前備份已保留：${result.backup}`);
            }
          } else {
            console.log("\n! 偵測到 CC Switch 通用配置缺少中文設定。");
            console.log("  如需授權自動同步（會先備份資料庫），重新執行並設定環境變數：");
            console.log("    macOS/Linux: ZH_CN_CCSWITCH_SYNC=1 node .../setup.js");
            console.log("    Windows:     set ZH_CN_CCSWITCH_SYNC=1 && node ...\\setup.js");
            console.log("  否則請手動在 CC Switch 的 Claude 通用配置中加入中文設定。");
          }
        }
      }
    }
  }

  // 3. patch 狀態
  console.log("\n--- CLI patch 狀態 ---");
  console.log(reportPatchStatus(pluginRoot));

  console.log("\n增強安裝完成。");
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(`\nsetup 失敗：${error.message}`);
    process.exit(1);
  }
}

module.exports = {
  buildOverlay,
  fillMissingKeys,
  ccSwitchConfigStatus,
  syncCcSwitch,
  settingsFile,
  ccSwitchDbPath,
};
