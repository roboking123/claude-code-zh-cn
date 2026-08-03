#!/usr/bin/env node

// plugin/scripts/build-overlay.js
//
// 從 plugin 內建資料構建中文在地化 overlay，並按需把缺失的 spinner 配置補進
// ~/.claude/settings.json。
//
// 這是 spinner 動詞/提示資料的執行期消費者，由三處共用：
//   - session-start (bash) hook   純 marketplace 安裝後首次自補齊
//   - session-start.ps1 hook      同上（Windows）
//   - plugin/skills/zh-cn-setup   互動式完整安裝
//
// 演算法與 scripts/install-json-helper.js 的 buildOverlay 完全一致（單一資料來源）。
// 資料檔案隨 plugin 包分發：plugin/verbs/zh-CN.json、plugin/tips/zh-CN.json、
// plugin/settings-overlay.json。這樣純 `claude plugin install` 安裝也能生效，
// 不依賴 install.sh / install.ps1 預生成的 .settings-overlay-cache.json。

"use strict";

const fs = require("node:fs");
const path = require("node:path");

const PLUGIN_KEYS = ["language", "spinnerTipsEnabled", "spinnerVerbs", "spinnerTipsOverride"];

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

// 與 install-json-helper.js buildOverlay 同款演算法。base/verbs/tips 缺失時優雅降級。
function buildOverlay(pluginRoot) {
  const baseFile = path.join(pluginRoot, "settings-overlay.json");
  const verbsFile = path.join(pluginRoot, "verbs", "zh-CN.json");
  const tipsFile = path.join(pluginRoot, "tips", "zh-CN.json");

  const base = isPlainObject(readJson(baseFile, null))
    ? readJson(baseFile, {})
    : { language: "Chinese", spinnerTipsEnabled: true };

  const verbs = readJson(verbsFile, null);
  const tips = readJson(tipsFile, null);

  if (Array.isArray(verbs) || (isPlainObject(verbs) && Array.isArray(verbs.verbs))) {
    base.spinnerVerbs = Array.isArray(verbs) ? verbs : verbs.verbs;
  }

  if (isPlainObject(tips) && Array.isArray(tips.tips)) {
    base.spinnerTipsOverride = {
      excludeDefault: true,
      tips: tips.tips.map((tip) => tip.text).filter((text) => typeof text === "string"),
    };
  }

  return base;
}

// 只補齊 settings 裡缺失的外掛 key，絕不覆蓋使用者已有的手動配置。
// 返回 { changed, merged }；呼叫方決定是否寫盤。
function fillMissingKeys(settingsFile, overlay) {
  const settings = isPlainObject(readJson(settingsFile, null)) ? readJson(settingsFile, {}) : {};
  const merged = { ...settings };
  let changed = false;

  for (const key of PLUGIN_KEYS) {
    if (!Object.prototype.hasOwnProperty.call(settings, key) && Object.prototype.hasOwnProperty.call(overlay, key)) {
      merged[key] = overlay[key];
      changed = true;
    }
  }

  return { changed, merged };
}

function writeSettings(settingsFile, merged) {
  const dir = path.dirname(settingsFile);
  fs.mkdirSync(dir, { recursive: true });
  // 原子寫：先寫臨時檔案再 rename，避免中途被打斷留下半份
  const tmp = `${settingsFile}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(merged, null, 2)}\n`);
  fs.renameSync(tmp, settingsFile);
}

// resolve overlay 資料來源優先順序：顯式傳入 > CLAUDE_PLUGIN_ROOT > 呼叫腳本所在 plugin 根
function resolvePluginRoot(explicit) {
  if (explicit) return path.resolve(explicit);
  if (process.env.CLAUDE_PLUGIN_ROOT) return path.resolve(process.env.CLAUDE_PLUGIN_ROOT);
  // 本檔案位於 <pluginRoot>/scripts/build-overlay.js
  return path.resolve(__dirname, "..");
}

function main(argv) {
  const [command, ...args] = argv;

  if (command === "build-overlay" && args.length <= 1) {
    const pluginRoot = resolvePluginRoot(args[0]);
    process.stdout.write(JSON.stringify(buildOverlay(pluginRoot)));
    return;
  }

  if (command === "ensure-settings" && args.length >= 1 && args.length <= 2) {
    const settingsFile = path.resolve(args[0]);
    const pluginRoot = resolvePluginRoot(args[1]);
    const overlay = buildOverlay(pluginRoot);
    const { changed, merged } = fillMissingKeys(settingsFile, overlay);
    if (changed) {
      writeSettings(settingsFile, merged);
      process.stdout.write("updated");
    } else {
      process.stdout.write("noop");
    }
    return;
  }

  console.error(
    [
      "Usage:",
      "  build-overlay.js build-overlay [plugin-root]",
      "  build-overlay.js ensure-settings <settings.json> [plugin-root]",
    ].join("\n")
  );
  process.exit(64);
}

if (require.main === module) {
  main(process.argv.slice(2));
}

module.exports = { buildOverlay, fillMissingKeys, writeSettings, resolvePluginRoot, PLUGIN_KEYS };
