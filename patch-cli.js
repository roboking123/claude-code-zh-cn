#!/usr/bin/env node
// patch-cli.js - cli.js 硬編碼文字中文 patch（安全版）
// 逐條翻譯：對每條翻譯用正則匹配 "..." 內的目標文本，安全替換
// 被 patch-cli.sh 呼叫
//
// 優雅降級契約：
// - 單條翻譯/結構化 patch 匹配不上 → 跳過該條，其餘照常（新版本改了文字 = 那條保持英文）
// - patch 結果必須通過 JS 語法校驗才落盤；校驗失敗 → 不寫任何東西，CLI 保持原樣可用
// - 任何意外異常 → 記錄日誌後按"未改動"結束（exit 0），絕不讓呼叫方誤以為 patch 成功
//
// 用法: patch-cli.js <cliFile> <translationsFile> [--backup <path>] [--status <file>] [--log <file>]
//   --backup  npm 託管備份模式：patch 前從同版本備份恢復乾淨基底；備份缺失/過期時自動重建
//   --status  寫入單詞狀態: ok | partial | noop | validation-failed | error
//   --log     錯誤日誌路徑（預設與本指令碼同目錄的 patch.log）

const fs = require("fs");
const os = require("os");
const path = require("path");
const vm = require("vm");

const positional = [];
const options = {};
{
    const argv = process.argv.slice(2);
    for (let i = 0; i < argv.length; i++) {
        if (argv[i] === "--backup" || argv[i] === "--status" || argv[i] === "--log") {
            options[argv[i].slice(2)] = argv[i + 1];
            i++;
        } else {
            positional.push(argv[i]);
        }
    }
}

const cliFile = positional[0];
const translationsFile = positional[1];

function defaultLogFile() {
    const pluginRoot =
        process.env.CLAUDE_PLUGIN_ROOT ||
        path.join(os.homedir(), ".claude", "plugins", "claude-code-zh-cn");
    if (fs.existsSync(pluginRoot)) {
        return path.join(pluginRoot, "patch.log");
    }
    return path.join(__dirname, "patch.log");
}

const logFile = options.log || defaultLogFile();

const RESIDUE_PROBES = [
    "Quick safety check",
    "This command requires approval",
    "Use /btw to ask a quick side question without interrupting Claude's current work",
];

const PATCHED_TRACE_PROBES = ["安全檢查：這是你自己建立", "等待權限確認…", "已切換模型為"];

function logEvent(message) {
    const line = `${new Date().toISOString()} ${message}\n`;
    try {
        try {
            const stat = fs.statSync(logFile);
            if (stat.size > 256 * 1024) {
                const tail = fs.readFileSync(logFile, "utf8").slice(-64 * 1024);
                fs.writeFileSync(logFile, tail);
            }
        } catch {}
        fs.appendFileSync(logFile, line);
    } catch {}
    process.stderr.write(line);
}

function writeStatus(status) {
    if (!options.status) return;
    try {
        fs.writeFileSync(options.status, status + "\n");
    } catch {}
}

function readVersionComment(text) {
    const match = text.match(/^\/\/ Version: (.+)$/m);
    return match ? match[1].trim() : "";
}

function looksPatched(text) {
    return PATCHED_TRACE_PROBES.some((probe) => text.includes(probe));
}

// 先用 vm.Script（CommonJS 語法，程序內、快）；失敗再退到 node --check
// （子程序，能正確解析 ESM——npm 的 cli.js 頂層有 import，vm.Script 必然報錯）。
function parsesAsJs(text) {
    try {
        new vm.Script(text, { filename: cliFile });
        return true;
    } catch {}
    try {
        const tmp = path.join(
            os.tmpdir(),
            `cczh-syntax-check.${process.pid}.${Math.random().toString(36).slice(2)}.mjs`
        );
        fs.writeFileSync(tmp, text);
        try {
            const result = require("child_process").spawnSync(process.execPath, ["--check", tmp], {
                stdio: "ignore",
                timeout: 30000,
            });
            return result.status === 0;
        } finally {
            try { fs.unlinkSync(tmp); } catch {}
        }
    } catch {
        return false;
    }
}

// 語法校驗策略：只有當"原文本身可被 Node 解析"時才要求 patch 結果也可解析。
// 原文就解析不了（如 native 提取的 Bun JS 含非標準語法）→ 跳過校驗，不誤攔。
function validateSyntax(before, after) {
    if (!parsesAsJs(before)) {
        logEvent(`validation-skipped ${cliFile}: source is not parseable by Node (e.g. native extract)`);
        return true;
    }
    if (parsesAsJs(after)) {
        return true;
    }
    logEvent(`validation-failed ${cliFile}: patched result is not valid JS, refusing to write`);
    return false;
}

function residueStatus(text) {
    return RESIDUE_PROBES.some((probe) => text.includes(probe)) ? "partial" : "ok";
}

function exitNoChange(status) {
    writeStatus(status);
    console.log("0");
    process.exit(0);
}

if (!cliFile || !fs.existsSync(cliFile)) {
    exitNoChange("noop");
}

const currentContent = fs.readFileSync(cliFile, "utf8");
let original = currentContent;

// --backup 託管備份模式：保證每次 patch 都基於乾淨的英文原文，杜絕 patch 疊 patch
if (options.backup) {
    const backupFile = options.backup;
    const currentVersion = readVersionComment(currentContent);
    let backupContent = null;
    if (fs.existsSync(backupFile)) {
        try {
            backupContent = fs.readFileSync(backupFile, "utf8");
        } catch {
            backupContent = null;
        }
    }

    if (backupContent !== null && currentVersion && readVersionComment(backupContent) === currentVersion) {
        // 同版本備份存在 → 用備份做乾淨基底
        original = backupContent;
    } else if (!looksPatched(currentContent)) {
        // 備份缺失/版本過期，且當前檔案未被 patch 過 → 當前檔案就是新 upstream 原文，重新整理備份
        try {
            fs.writeFileSync(backupFile, currentContent);
        } catch (error) {
            logEvent(`backup-refresh-failed ${backupFile}: ${error.message}`);
        }
        original = currentContent;
    } else {
        // 備份不可用且當前檔案已被 patch 過：沒有乾淨基底。
        // 繼續在當前檔案上做增量 patch（翻譯規則對已翻譯文本天然冪等），語法校驗兜底。
        logEvent(`no-clean-backup ${cliFile}: patching in place (backup missing or version mismatch)`);
        original = currentContent;
    }
}

let s = original;
let count = 0;

// 全域性兜底：任何未預期異常都按"未改動"結束，絕不落半成品
process.on("uncaughtException", (error) => {
    logEvent(`unexpected-error ${cliFile}: ${error && error.stack ? error.stack : error}`);
    writeStatus("error");
    console.log("0");
    process.exit(0);
});

// === Helper：直接全量替換（僅用於特殊 patch，匹配特定程式碼模式）===
// 單條 patch 內部異常只跳過該條（優雅降級），不中斷整體流程

function tryReplace(from, to) {
    if (s.includes(from)) {
        s = s.split(from).join(to);
        count++;
        return true;
    }
    return false;
}

function tryRegexReplace(pattern, replacer) {
    let hit = false;
    try {
        const replaced = s.replace(pattern, (...args) => {
            const match = args[0];
            const result = replacer(...args);
            if (result !== match) hit = true;
            return result;
        });
        if (hit) {
            s = replaced;
            count++;
        }
    } catch (error) {
        logEvent(`structural-patch-skipped ${pattern}: ${error.message}`);
        return false;
    }
    return hit;
}

function escapeRegExp(text) {
    return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function asDoubleQuotedLiteral(text) {
    return JSON.stringify(text);
}

function splitApostropheLiteral(text) {
    if (!text.includes("'")) {
        return [text];
    }

    const parts = [];
    const segments = text.split("'");
    segments.forEach((segment, index) => {
        parts.push(segment);
        if (index !== segments.length - 1) {
            parts.push("'");
        }
    });
    return parts;
}

function trySplitDoubleQuotedLiteralReplace(en, zh) {
    const parts = splitApostropheLiteral(en);
    if (parts.length === 1) {
        return false;
    }

    const pattern = new RegExp(
        parts.map((part) => escapeRegExp(asDoubleQuotedLiteral(part))).join(String.raw`\s*,\s*`),
        "g"
    );
    return tryRegexReplace(pattern, () => asDoubleQuotedLiteral(zh));
}

function escapeSingleQuotedLiteralContent(text) {
    return text
        .replace(/\\/g, "\\\\")
        .replace(/\r/g, "\\r")
        .replace(/\n/g, "\\n")
        .replace(/\t/g, "\\t")
        .replace(/\u2028/g, "\\u2028")
        .replace(/\u2029/g, "\\u2029")
        .replace(/'/g, "\\'");
}

function escapeSingleQuotedLiteralNeedleContent(text) {
    return text
        .replace(/\r/g, "\\r")
        .replace(/\n/g, "\\n")
        .replace(/\t/g, "\\t")
        .replace(/\u2028/g, "\\u2028")
        .replace(/\u2029/g, "\\u2029")
        .replace(/'/g, "\\'");
}

function replaceTemplateLiteralTextParts(parts, en, zh) {
    let hit = false;
    for (const part of parts) {
        if (part.type !== "text" || !part.value.includes(en)) {
            continue;
        }
        const replaced = replaceLiteralText(part.value, en, zh);
        if (replaced === part.value) {
            continue;
        }
        part.value = replaced;
        hit = true;
    }
    return hit;
}

function splitTemplateSegments(text) {
    return text.split(/\$\{[^}]+\}/g);
}

function replaceWholeTemplateLiteral(literal, en, zh) {
    const exprParts = literal.parts.filter((part) => part.type === "expr");
    if (exprParts.length === 0) {
        return false;
    }

    const enSegments = splitTemplateSegments(en);
    const zhSegments = splitTemplateSegments(zh);
    if (enSegments.length !== exprParts.length + 1 || zhSegments.length !== exprParts.length + 1) {
        return false;
    }

    let segmentIndex = 0;
    for (const part of literal.parts) {
        if (part.type !== "text") {
            continue;
        }
        if (part.value !== enSegments[segmentIndex++]) {
            return false;
        }
    }
    if (segmentIndex !== enSegments.length) {
        return false;
    }

    segmentIndex = 0;
    let textIndex = 0;
    for (const part of literal.parts) {
        if (part.type !== "text") {
            continue;
        }
        part.value = zhSegments[textIndex++] ?? "";
    }
    literal.text = literal.parts.map((part) => part.value).join("");
    return true;
}

function scanStringLiterals(source) {
    const literals = [];
    const regexAllowedKeywords = new Set([
        "case",
        "delete",
        "do",
        "else",
        "in",
        "instanceof",
        "new",
        "of",
        "return",
        "throw",
        "typeof",
        "void",
        "yield",
        "await",
    ]);

    let state = "code";
    let i = 0;
    let start = -1;
    let prevToken = { type: "start", value: "" };
    const templateStack = [];
    let recordStringLiteral = true;

    function setPrevToken(type, value = "") {
        prevToken = { type, value };
    }

    function currentTemplate() {
        return templateStack[templateStack.length - 1] ?? null;
    }

    function isIdentifierStart(ch) {
        return /[A-Za-z_$]/.test(ch);
    }

    function isIdentifierPart(ch) {
        return /[A-Za-z0-9_$]/.test(ch);
    }

    function isDigit(ch) {
        return ch >= "0" && ch <= "9";
    }

    function canStartRegex() {
        if (prevToken.type === "start") return true;
        if (prevToken.type === "operator") return true;
        if (prevToken.type === "open") return true;
        if (prevToken.type === "comma") return true;
        if (prevToken.type === "colon") return true;
        if (prevToken.type === "question") return true;
        if (prevToken.type === "templateExprStart") return true;
        if (prevToken.type === "keyword" && regexAllowedKeywords.has(prevToken.value)) return true;
        return false;
    }

    while (i < source.length) {
        const ch = source[i];
        const next = source[i + 1];

        switch (state) {
            case "code":
                if (/\s/.test(ch)) {
                    i++;
                    continue;
                }

                if (ch === '"') {
                    start = i;
                    recordStringLiteral = !(currentTemplate() && currentTemplate().exprDepth > 0);
                    state = "double";
                    i++;
                    continue;
                }

                if (ch === "'") {
                    start = i;
                    recordStringLiteral = !(currentTemplate() && currentTemplate().exprDepth > 0);
                    state = "single";
                    i++;
                    continue;
                }

                if (ch === "`") {
                    start = i;
                    templateStack.push({
                        start,
                        parts: [],
                        textStart: i + 1,
                        exprStart: -1,
                        exprDepth: 0,
                        recordLiteral: !(currentTemplate() && currentTemplate().exprDepth > 0),
                    });
                    state = "template";
                    i++;
                    continue;
                }

                if (ch === "/" && next === "/") {
                    state = "lineComment";
                    i += 2;
                    continue;
                }

                if (ch === "/" && next === "*") {
                    state = "blockComment";
                    i += 2;
                    continue;
                }

                if (ch === "/") {
                    if (canStartRegex()) {
                        state = "regex";
                        i++;
                        continue;
                    }
                    setPrevToken("operator", "/");
                    i++;
                    continue;
                }

                if (isIdentifierStart(ch)) {
                    let j = i + 1;
                    while (j < source.length && isIdentifierPart(source[j])) j++;
                    const word = source.slice(i, j);
                    setPrevToken(regexAllowedKeywords.has(word) ? "keyword" : "identifier", word);
                    i = j;
                    continue;
                }

                if (isDigit(ch)) {
                    let j = i + 1;
                    while (j < source.length && /[0-9A-Fa-f_xXobBeE.+-]/.test(source[j])) j++;
                    setPrevToken("number", source.slice(i, j));
                    i = j;
                    continue;
                }

                if (ch === "{") {
                    const template = currentTemplate();
                    if (template && template.exprDepth > 0) {
                        template.exprDepth++;
                    }
                    setPrevToken("open", ch);
                    i++;
                    continue;
                }

                if (ch === "}") {
                    const template = currentTemplate();
                    if (template && template.exprDepth > 0) {
                        template.exprDepth--;
                        if (template.exprDepth === 0) {
                            template.parts.push({
                                type: "expr",
                                value: source.slice(template.exprStart, i + 1),
                            });
                            template.exprStart = -1;
                            template.textStart = i + 1;
                            setPrevToken("templateExprEnd", ch);
                            state = "template";
                            i++;
                            continue;
                        }
                    }
                    setPrevToken("close", ch);
                    i++;
                    continue;
                }

                if (ch === "(" || ch === "[") {
                    setPrevToken("open", ch);
                    i++;
                    continue;
                }

                if (ch === ")" || ch === "]") {
                    setPrevToken("close", ch);
                    i++;
                    continue;
                }

                if (ch === ",") {
                    setPrevToken("comma", ch);
                    i++;
                    continue;
                }

                if (ch === ":") {
                    setPrevToken("colon", ch);
                    i++;
                    continue;
                }

                if (ch === "?") {
                    setPrevToken("question", ch);
                    i++;
                    continue;
                }

                if (ch === "=" && next === ">") {
                    setPrevToken("operator", "=>");
                    i += 2;
                    continue;
                }

                setPrevToken("operator", ch);
                i++;
                continue;

            case "double":
                if (ch === "\\") {
                    i += 2;
                    continue;
                }
                if (ch === '"') {
                    if (recordStringLiteral) {
                        literals.push({
                            start,
                            end: i + 1,
                            text: source.slice(start + 1, i),
                            quote: '"',
                        });
                    }
                    setPrevToken("string");
                    state = "code";
                    i++;
                    continue;
                }
                i++;
                continue;

            case "single":
                if (ch === "\\") {
                    i += 2;
                    continue;
                }
                if (ch === "'") {
                    if (recordStringLiteral) {
                        literals.push({
                            start,
                            end: i + 1,
                            text: source.slice(start + 1, i),
                            quote: "'",
                        });
                    }
                    setPrevToken("string");
                    state = "code";
                    i++;
                    continue;
                }
                i++;
                continue;

            case "template":
                if (ch === "\\") {
                    i += 2;
                    continue;
                }
                if (ch === "`") {
                    const template = templateStack.pop();
                    template.parts.push({
                        type: "text",
                        value: source.slice(template.textStart, i),
                    });
                    if (template.recordLiteral) {
                        literals.push({
                            start: template.start,
                            end: i + 1,
                            text: template.parts.map((part) => part.value).join(""),
                            quote: "`",
                            parts: template.parts,
                        });
                    }
                    setPrevToken("template");
                    state = "code";
                    i++;
                    continue;
                }
                if (ch === "$" && next === "{") {
                    const template = currentTemplate();
                    template.parts.push({
                        type: "text",
                        value: source.slice(template.textStart, i),
                    });
                    template.exprStart = i;
                    template.exprDepth = 1;
                    setPrevToken("templateExprStart", "${");
                    state = "code";
                    i += 2;
                    continue;
                }
                i++;
                continue;

            case "lineComment":
                if (ch === "\n" || ch === "\r") {
                    state = "code";
                }
                i++;
                continue;

            case "blockComment":
                if (ch === "*" && next === "/") {
                    state = "code";
                    i += 2;
                    continue;
                }
                i++;
                continue;

            case "regex":
                if (ch === "\\") {
                    i += 2;
                    continue;
                }
                if (ch === "[") {
                    state = "regexClass";
                    i++;
                    continue;
                }
                if (ch === "/") {
                    i++;
                    while (i < source.length && /[A-Za-z]/.test(source[i])) i++;
                    setPrevToken("regex");
                    state = "code";
                    continue;
                }
                i++;
                continue;

            case "regexClass":
                if (ch === "\\") {
                    i += 2;
                    continue;
                }
                if (ch === "]") {
                    state = "regex";
                    i++;
                    continue;
                }
                i++;
                continue;
        }
    }

    return literals;
}

function replaceLiteralText(text, en, zh) {
    const wordLike = en.match(/^([^A-Za-z0-9_$]*)([A-Za-z][A-Za-z0-9_$]*)([^A-Za-z0-9_$]*)$/);
    if (!wordLike) {
        return text.split(en).join(zh);
    }

    const [, , word] = wordLike;
    const enEscaped = en.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const pattern = new RegExp(`(^|[^A-Za-z0-9_$])(${enEscaped})(?=$|[^A-Za-z0-9_$])`, "g");
    return text.replace(pattern, (match, boundary) => boundary + zh);
}

const specialSplitLiteralTranslations = [
    {
        en: "Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team). If not, take a moment to review what's in this folder first.",
        zh: "安全檢查：這是你自己建立或信任的專案嗎？（例如你自己的程式碼、知名開源專案、或團隊的工作）。如果不是，請先檢視此資料夾中的內容。",
    },
    {
        en: "Claude Code'll be able to read, edit, and execute files here.",
        zh: "Claude Code 將能在此目錄中讀取、編輯和執行檔案。",
    },
];

const specialLiteralTranslations = [
    { en: "Tab to amend", zh: "按 Tab 修改" },
    { en: "ctrl+e to explain", zh: "按 ctrl+e 說明" },
    { en: "Any Bash command starting with", zh: "任意 Bash 指令以" },
    { en: "任意 Bash 指令 starting with", zh: "任意 Bash 指令以" },
    { en: "The Bash command ", zh: "Bash 指令 " },
    { en: "Requires manual approval", zh: "需要手動核准" },
    { en: "Waiting\\u2026", zh: "等待中…" },
    { en: "Waiting for permission\\u2026", zh: "等待權限確認…" },
    { en: "Working\\u2026", zh: "工作中…" },
    { en: "Yes, and don\\u2019t ask again for", zh: "是，不再詢問" },
    { en: "Yes, and don’t ask again for", zh: "是，不再詢問" },
    { en: " ready · shift+↓ to view", zh: " 已就緒 · 按 shift+↓ 檢視" },
    { en: "Failed to save ", zh: "儲存失敗：" },
];

function translateFastModeTemplateLiteral(literal) {
    const exprParts = literal.parts?.filter((part) => part.type === "expr") ?? [];
    const textParts = literal.parts?.filter((part) => part.type === "text") ?? [];
    if (exprParts.length !== 1 || textParts.length !== 2) {
        return false;
    }

    if (textParts[0].value !== "Toggle fast mode (") {
        return false;
    }

    const hasOnlySuffix = textParts[1].value === " only)";
    if (textParts[1].value !== ")" && !hasOnlySuffix) {
        return false;
    }

    textParts[0].value = hasOnlySuffix ? "切換快速模式（僅 " : "切換快速模式（";
    textParts[1].value = "）";
    literal.text = literal.parts.map((part) => part.value).join("");
    return true;
}

function applyDynamicLiteralTranslations(text) {
    return text.replace(/Toggle fast mode \((Opus [^)]+?)( only)?\)/g, (_match, model, only) => {
        return only ? `切換快速模式（僅 ${model}）` : `切換快速模式（${model}）`;
    });
}

function shouldSkipTranslationRule(rule) {
    return rule && (rule.skipPatch === true || rule.skipPatch === "model-prompt-contract");
}

function installStatuslinePromptPathGuard() {
    const source =
        "Your job is to create or update the statusLine command in the user's Claude Code settings.\n\nWhen asked to convert the user's shell PS1 configuration, follow these steps:";
    const replacement =
        "Your job is to create or update the statusLine command in the user's Claude Code settings.\n\nPath handling for tools:\n- Use shell-relative paths exactly as written when calling tools: ~/.zshrc, ~/.bashrc, ~/.bash_profile, ~/.profile, and ~/.claude/settings.json.\n- Never invent or guess an absolute /Users/... path; the host resolves ~ for the current user.\n\nWhen asked to convert the user's shell PS1 configuration, follow these steps:";
    tryReplace(source, replacement);
}

function installStatuslineCommandPromptPathGuard() {
    const guard =
        " CRITICAL TOOL PATH RULE: use only ~/.zshrc, ~/.bashrc, ~/.bash_profile, ~/.profile, and ~/.claude/settings.json when calling Read, Edit, or Write; never use an absolute /Users/... path.";
    tryRegexReplace(
        /`Create an \$\{([^}]+)\} with subagent_type "statusline-setup" and the prompt "\$\{([^}]+)\}"`/g,
        (match, agentExpr, promptExpr) => {
            if (match.includes("CRITICAL TOOL PATH RULE")) {
                return match;
            }
            return (
                "`Create an ${" +
                agentExpr +
                '} with subagent_type "statusline-setup" and the prompt "${' +
                promptExpr +
                "}" +
                guard +
                '"`'
            );
        }
    );
}

function installDurationFormatterLocalization() {
    const signature = /function\s+[A-Za-z0-9_$]+\([^)]*\)\{if\([A-Za-z0-9_$]+<60000\)/g;
    let match;

    while ((match = signature.exec(s)) !== null) {
        const fnStart = match.index;
        const bodyStart = s.indexOf("{", fnStart);
        if (bodyStart === -1) continue;

        let depth = 0;
        let fnEnd = -1;
        for (let i = bodyStart; i < s.length; i++) {
            if (s[i] === "{") depth++;
            else if (s[i] === "}") depth--;
            if (depth === 0) {
                fnEnd = i;
                break;
            }
        }
        if (fnEnd === -1) continue;

        let fn = s.slice(fnStart, fnEnd + 1);
        if (!fn.includes("mostSignificantOnly") || !fn.includes("toFixed(1)") || !fn.includes("Math.floor")) {
            continue;
        }

        const localized = fn
            .replace(/"0s"/g, '"0秒"')
            .replace(/}d\s+\$\{/g, "}天${")
            .replace(/}h\s+\$\{/g, "}小時${")
            .replace(/}m\s+\$\{/g, "}分${")
            .replace(/}d/g, "}天")
            .replace(/}h/g, "}小時")
            .replace(/}m/g, "}分")
            .replace(/}s/g, "}秒");

        if (localized !== fn) {
            s = s.slice(0, fnStart) + localized + s.slice(fnEnd + 1);
            count++;
            signature.lastIndex = fnStart + localized.length;
        }
    }
}

function installIssue80VisibleResidueLocalization() {
    // Dynamic UI fragments from Claude Code 2.1.153: keep these structural so
    // broad shards like "Install the " and "Set model to " do not leak into prompts.
    tryRegexReplace(
        /([A-Za-z0-9_$]+(?:\.default)?)\.createElement\(([^,]+),null,"Install the ",\1\.createElement\(\2,\{color:"ide"\},([A-Za-z0-9_$]+)\)," plugin from the JetBrains Marketplace:"," ",\1\.createElement\(\2,\{bold:!0\},"https:\/\/docs\.claude\.com\/s\/claude-code-jetbrains"\)\)/g,
        (match, factory, component, ideName) =>
            `${factory}.createElement(${component},null,"從 JetBrains Marketplace 安裝 ",${factory}.createElement(${component},{color:"ide"},${ideName})," 外掛："," ",${factory}.createElement(${component},{bold:!0},"https://docs.claude.com/s/claude-code-jetbrains"))`
    );

    tryRegexReplace(
        /let ([A-Za-z0-9_$]+)=`Set model to \$\{([^}]+)\}\$\{([^}]+)\?" and saved as your default for new sessions":" for this session only"\}`/g,
        (match, messageVar, modelExpr, defaultExpr) =>
            `let ${messageVar}=\`已切換模型為 \${${modelExpr}}\${${defaultExpr}?"，並已儲存為新工作階段預設模型":"（僅本次工作階段）"}\``
    );

    tryRegexReplace(
        /(\blet\s+|,)([A-Za-z0-9_$]+)=`Model set to \$\{([^}]+)\}\$\{([^}]+)\?" and saved as your default for new sessions":" for this session only"\}`/g,
        (match, prefix, messageVar, modelExpr, defaultExpr) =>
            `${prefix}${messageVar}=\`已切換模型為 \${${modelExpr}}\${${defaultExpr}?"，並已儲存為新工作階段預設模型":"（僅本次工作階段）"}\``
    );

    tryRegexReplace(
        /([A-Za-z0-9_$]+)\(`Set model to \$\{([^}]+)\}`\)/g,
        (match, notifyFn, modelExpr) => `${notifyFn}(\`已切換模型為 \${${modelExpr}}\`)`
    );

    tryRegexReplace(
        /return`Review the current diff for correctness bugs and reuse\/simplification\/efficiency cleanups at the given effort level \(low\/medium: fewer, high-confidence findings; high\\u2192max: broader coverage, may include uncertain findings\$\{([\s\S]*?)\}\)\. Pass --comment to post findings as inline PR comments, or --fix to apply the findings to the working tree after the review\.`/g,
        (match, ultraExpr) => {
            const localizedUltraExpr = ultraExpr
                .replace(/; ultra: deep multi-agent review in the cloud/g, "；ultra：雲端深度多 Agent review")
                .replace(/ \(requires claude\.ai account access\)/g, "（需要 claude.ai 賬號權限）");
            return `return\`審查目前 diff 的正確性問題，以及複用性、簡化和效率改進；按指定 effort 級別執行（low/medium：只報更少、更高置信的問題；high→max：覆蓋更廣，可能包含不確定問題\${${localizedUltraExpr}}）。傳 --comment 可將發現釋出為 PR 行內評論，傳 --fix 可在 review 後把發現應用到工作區。\``;
        }
    );
}

function installEffortAndWorkflowFooterLocalization() {
    tryRegexReplace(
        /`\$\{([^`]+?)\} to adjust \\xB7 \$\{([^`]+?)\} to confirm \\xB7 \$\{([^`]+?)\} to cancel`/g,
        (match, adjustKeys, confirmKeys, cancelKeys) =>
            `\`\${${adjustKeys}} 調整 · \${${confirmKeys}} 確認 · \${${cancelKeys}} 取消\``
    );

    tryRegexReplace(
        /([A-Za-z0-9_$]+)\.createElement\(([A-Za-z0-9_$]+),null,\1\.createElement\(([A-Za-z0-9_$]+),\{chord:\["left","right"\],action:"adjust"\}\),\1\.createElement\(\3,\{chord:"enter",action:"confirm"\}\),\1\.createElement\(\3,\{chord:"escape",action:"cancel"\}\)\)/g,
        (match, factory, wrapper) =>
            `${factory}.createElement(${wrapper},null,"←/→ 調整 · Enter 確認 · Esc 取消")`
    );

    tryRegexReplace(
        /(?:[A-Za-z0-9_$]+\.)?[A-Za-z0-9_$]+\.createElement\(([A-Za-z0-9_$]+),\{chord:"escape",action:"close"\}\)/g,
        () => '"Esc 關閉"'
    );
}

function installCommonVisibleResidueLocalization() {
    tryRegexReplace(
        /([A-Za-z0-9_$]+(?:\.default)?)\.createElement\(([A-Za-z0-9_$]+),null,\1\.createElement\(([A-Za-z0-9_$]+),\{chord:"enter",action:"confirm"\}\),\1\.createElement\(\3,\{chord:"escape",action:"cancel"\}\)\)/g,
        (match, factory, wrapper) =>
            `${factory}.createElement(${wrapper},null,"Enter 確認","Esc 取消")`
    );

    tryRegexReplace(
        /([A-Za-z0-9_$]+(?:\.default)?)\.createElement\(([A-Za-z0-9_$]+),null,\1\.createElement\(([A-Za-z0-9_$]+),\{chord:"enter",action:"confirm"\}\),\1\.createElement\([A-Za-z0-9_$]+,\{action:"confirm:no",context:"Confirmation",fallback:"Esc",description:"cancel"\}\)\)/g,
        (match, factory, wrapper) =>
            `${factory}.createElement(${wrapper},null,"Enter 確認","Esc 取消")`
    );

    tryRegexReplace(/" for agents"/g, () => '" 檢視 Agent"');
    tryRegexReplace(/"for agents"/g, () => '"檢視 Agent"');
    tryRegexReplace(/"again "/g, () => '"再次 "');
}

function installWorkflowLifecycleResidueLocalization() {
    tryRegexReplace(
        /`Dynamic workflow requested for this turn\$\{([A-Za-z0-9_$]+)\?` \\xB7 \$\{\1\} to ignore`:""\}`/g,
        (match, keyHint) =>
            "`本輪已請求動態工作流${" + keyHint + "?` · ${" + keyHint + "} 忽略`:\"\"}`"
    );

    tryRegexReplace(
        /`Ultracode keyword ignored for this prompt\$\{([A-Za-z0-9_$]+)\?` \\xB7 \$\{\1\} to undo`:""\}`/g,
        (match, keyHint) =>
            "`已忽略本條提示詞中的 Ultracode 關鍵詞${" + keyHint + "?` · ${" + keyHint + "} 復原`:\"\"}`"
    );
}

// === 特殊 patch（基於精確程式碼模式匹配，安全）===
// 這些 patch 匹配非常特定的程式碼模式，不會誤傷識別符號

// 0. /statusline 內部 agent prompt 防守：第三方模型容易猜錯 /Users/... 絕對路徑。
// 保持英文，不做中文化；只強化工具路徑契約。
// 每個結構化 patch 獨立執行，單個失敗只跳過該項（記日誌），其餘照常。
for (const step of [
    installStatuslinePromptPathGuard,
    installStatuslineCommandPromptPathGuard,
    installDurationFormatterLocalization,
    installIssue80VisibleResidueLocalization,
    installEffortAndWorkflowFooterLocalization,
    installCommonVisibleResidueLocalization,
    installWorkflowLifecycleResidueLocalization,
]) {
    try {
        step();
    } catch (error) {
        logEvent(`structural-step-skipped ${step.name}: ${error.message}`);
    }
}

// 1. 過去式動詞陣列
tryRegexReplace(
    /\["Baked","Brewed","Churned","Cogitated","Cooked","Crunched","Saut(?:\u00e9|\\u00e9|\\xE9)ed","Worked"\]/g,
    () => '["烘焙了","泡茶了","翻攪了","琢磨了","烹飪了","咀嚼了","翻炒了","忙了"]'
);

// 2. Tip: → 💡
const tipMatch = s.match(/`Tip: \$\{[^}]+\}`/);
if (tipMatch) {
    const replaced = tipMatch[0].replace("Tip: ", "\u{1F4A1} ");
    s = s.split(tipMatch[0]).join(replaced);
    count++;
}

// 3. Duration formatter（時間單位中文化）
const marker = "if(q<60000)";
const markerIdx = s.indexOf(marker);
if (markerIdx !== -1) {
    const fnStart = s.lastIndexOf("function", markerIdx);
    if (fnStart !== -1) {
        let depth = 0, fnEnd = -1;
        for (let i = s.indexOf("{", fnStart); i < s.length; i++) {
            if (s[i] === "{") depth++;
            else if (s[i] === "}") depth--;
            if (depth === 0) { fnEnd = i; break; }
        }
        if (fnEnd !== -1) {
            let fn = s.substring(fnStart, fnEnd + 1);
            const pairs = [
                ["}d ${z}h ${Y}m ${$}s", "}天${z}小時${Y}分${$}秒"],
                ["}d ${z}h ${Y}m", "}天${z}小時${Y}分"],
                ["}h ${Y}m ${$}s", "}小時${Y}分${$}秒"],
                ["}d ${z}h", "}天${z}小時"],
                ["}h ${Y}m", "}小時${Y}分"],
                ["}m ${$}s", "}分${$}秒"],
                ["}d", "}天"],
                ["}h", "}小時"],
                ["}m", "}分"],
                ["}s", "}秒"],
                ['"0s"', '"0秒"'],
            ];
            let changed = false;
            pairs.forEach(([from, to]) => {
                if (fn.includes(from)) {
                    fn = fn.split(from).join(to);
                    changed = true;
                }
            });
            if (changed) {
                s = s.substring(0, fnStart) + fn + s.substring(fnEnd + 1);
                count++;
            }
        }
    }
}

// 4. 去掉 duration display 的 "for" 連線詞
// 原始: createElement(T, ..., verb, " for ", duration) → "沏了 for 27分26秒"
// 修復: " for " → " "（僅匹配 createElement 文本節點模式）
tryReplace('," for ",', '," ",');
tryReplace('"Idle for "', '"閒置 "');

// 4b. 主 spinner 的 duration display（反引號模板字串）
// 原: `${bL} Worked for ${w3(Date.now()-V.startTime)}` → "烘焙了 Worked for 27分26秒"
// 修: `${bL} ${w3(Date.now()-V.startTime)}` → "烘焙了 27分26秒"
tryReplace(' Worked for ${w3(Date.now()-V.startTime)}', ' ${w3(Date.now()-V.startTime)}');
tryReplace('${bL} Idle', '${bL} 閒置');

// 4c. 同類 duration 模板的泛化匹配
// 某些版本會改變數名或表示式，但模板結構仍是 `${verb} Worked for ${duration}`。
// 這裡按模板形態處理，不再依賴固定變數名。
tryRegexReplace(/\$\{[^}]+\}\s+Worked for\s+\$\{[^}]+\}/g, (match) =>
    match.replace(" Worked for ", " ")
);
tryRegexReplace(/\?`Worked for \$\{([^}]+)\}`:"Idle"/g, (match, durationExpr) =>
    `?\`忙了 \${${durationExpr}}\`:"閒置"`
);
tryRegexReplace(/\$\{[^}]+\}\s+Idle(?=[`"])/g, (match) =>
    match.replace(" Idle", " 閒置")
);

// 4d. 訊息完成後的狀態行（顯示 "翻攪了 for 51秒" 的地方）
// 原: let G=H&&`${O} for ${M}`  （O=動詞, M=時長）
// 修: let G=H&&`${O} ${M}`     → "翻攪了 51秒"
tryReplace('`${O} for ${M}`', '`${O} ${M}`');
tryRegexReplace(/&&`\$\{[^}]+\} for \$\{[^}]+\}`/g, (match) =>
    match.replace(" for ", " ")
);

// 4e. /clear 省上下文提示（split fragment → 穩定模板）
tryRegexReplace(
    /([A-Za-z0-9_$]+(?:\.default)?)\.createElement\(([^,]+),\{color:"suggestion"\},"\/clear"\),\1\.createElement\(\2,\{dimColor:!0\}," to save "\),\1\.createElement\(\2,\{color:"suggestion"\},([A-Za-z0-9_$]+)," tokens"\)/g,
    (match, factory, component, tokenCount) =>
        `${factory}.createElement(${component},{color:"suggestion"},"/clear"),${factory}.createElement(${component},{dimColor:!0}," 儲存 "),${factory}.createElement(${component},{color:"suggestion"},${tokenCount}," tokens")`
);

// 5. 儲存並編輯快捷鍵提示（split fragment → 穩定模板）
tryRegexReplace(
    /([A-Za-z0-9_$]+(?:\.default)?)\.createElement\(([^,]+),\{color:"success"\},"Press ",([A-Za-z0-9_$]+)," or ",([A-Za-z0-9_$]+)," to save,"," ",\1\.createElement\(\2,\{bold:!0\},"e"\)," to save and edit"\)/g,
    (match, factory, component, primaryKey, secondaryKey) =>
        `${factory}.createElement(${component},{color:"success"},"按 ",${primaryKey}," 或 ",${secondaryKey}," 儲存，按 ",${factory}.createElement(${component},{bold:!0},"e")," 儲存並編輯")`
);

// 6. Quick Launch / plan open 等單點高風險 UI 片段遷移到結構化 patch
tryRegexReplace(
    /([A-Za-z0-9_$]+(?:\.default)?)\.createElement\(([^,]+),null,"• Cmd\+Esc",\1\.createElement\(\2,\{dimColor:!0\}," for Quick Launch"\)\)/g,
    (match, factory, component) =>
        `${factory}.createElement(${component},null,"• 快速啟動",${factory}.createElement(${component},{dimColor:!0}," · Cmd+Esc"))`
);
tryRegexReplace(
    /([A-Za-z0-9_$]+(?:\.default)?)\.createElement\(([^,]+),\{marginTop:1\},\1\.createElement\(([^,]+),\{dimColor:!0\},['"]"\/plan open"['"]\),\1\.createElement\(\3,\{dimColor:!0\}," to edit this plan in "\),\1\.createElement\(\3,\{bold:!0,dimColor:!0\},([A-Za-z0-9_$]+)\)\)/g,
    (match, factory, containerComponent, textComponent, terminalName) =>
        `${factory}.createElement(${containerComponent},{marginTop:1},${factory}.createElement(${textComponent},{dimColor:!0},"在 "),${factory}.createElement(${textComponent},{bold:!0,dimColor:!0},${terminalName}),${factory}.createElement(${textComponent},{dimColor:!0},' 中用 "/plan open" 編輯此計劃'))`
);

// 7. 權限確認面板的新 native UI 片段（避免全域性翻譯 Bash/Yes/No 誤傷系統提示）
tryRegexReplace(
    /title:([A-Za-z0-9_$]+)&&!([A-Za-z0-9_$]+)\?"Bash command \(unsandboxed\)":"Bash command"/g,
    (match, sandboxed, visible) =>
        `title:${sandboxed}&&!${visible}?"Bash 指令（未沙盒隔離）":"Bash 指令"`
);
tryRegexReplace(/label:"Yes",value:"yes"/g, () => 'label:"是",value:"yes"');
tryRegexReplace(/label:"No",value:"no"/g, () => 'label:"否",value:"no"');
tryRegexReplace(
    /([A-Za-z0-9_$]+(?:\.default)?)\.createElement\(([^,]+),\{dimColor:!0\},"Any use of the ",\1\.createElement\(\2,\{bold:!0\},([^)]*)\)," tool"\)/g,
    (match, factory, component, toolName) =>
        `${factory}.createElement(${component},{dimColor:!0},"任意使用 ",${factory}.createElement(${component},{bold:!0},${toolName})," 工具")`
);

// === 逐條翻譯：只替換真實的字串字面量 ===
//
// 先處理 minifier 把 `'` 拆成 `"foo","'","bar"` 的高風險字面量（folder trust、/btw 等），
// 再掃描原始碼中的真實字串 token，只在這些 token 內做替換。
// 這樣不會跨越原始碼結構誤改物件鍵、識別符號或註釋。

if (translationsFile && fs.existsSync(translationsFile)) {
    const translationRules = [
        ...JSON.parse(fs.readFileSync(translationsFile, "utf8")).filter(
            (rule) => !shouldSkipTranslationRule(rule)
        ),
        ...specialLiteralTranslations,
        ...specialSplitLiteralTranslations,
    ];
    translationRules.sort((a, b) => b.en.length - a.en.length);

    for (const { en, zh } of translationRules) {
        if (en === zh || !en.includes("'")) {
            continue;
        }
        trySplitDoubleQuotedLiteralReplace(en, zh);
    }

    const literals = scanStringLiterals(s);
    let literalsChanged = false;

    for (const literal of literals) {
        if (literal.quote === "`") {
            if (translateFastModeTemplateLiteral(literal)) {
                literalsChanged = true;
                count++;
            }
            continue;
        }

        const replaced = applyDynamicLiteralTranslations(literal.text);
        if (replaced !== literal.text) {
            literal.text = replaced;
            literalsChanged = true;
            count++;
        }
    }

    for (const { en, zh } of translationRules) {
        if (en === zh) continue;

        let hit = false;
        for (const literal of literals) {
            if (literal.quote === "`") {
                if (!replaceWholeTemplateLiteral(literal, en, zh)) {
                    if (!replaceTemplateLiteralTextParts(literal.parts, en, zh)) {
                        continue;
                    }
                    literal.text = literal.parts.map((part) => part.value).join("");
                }
                hit = true;
                literalsChanged = true;
                continue;
            }

            const needle = literal.quote === "'" ? escapeSingleQuotedLiteralNeedleContent(en) : en;
            const replacementText = literal.quote === "'" ? escapeSingleQuotedLiteralContent(zh) : zh;
            if (!literal.text.includes(needle)) {
                continue;
            }
            const replaced = replaceLiteralText(literal.text, needle, replacementText);
            if (replaced === literal.text) {
                continue;
            }
            literal.text = replaced;
            hit = true;
            literalsChanged = true;
        }

        if (hit) count++;
    }

    if (literalsChanged) {
        let rebuilt = "";
        let cursor = 0;
        for (const literal of literals) {
            rebuilt += s.slice(cursor, literal.start + 1);
            rebuilt += literal.text;
            rebuilt += literal.quote;
            cursor = literal.end;
        }
        rebuilt += s.slice(cursor);
        s = rebuilt;
    }
}

// === 只有實際改變檔案內容才寫入 ===
// s 是基於乾淨基底（original）patch 後的完整結果；currentContent 是磁碟上的現狀。
// 兩者一致 → 無需寫盤；不一致 → 語法校驗通過後原子替換。
if (s === currentContent) {
    exitNoChange(residueStatus(s) === "ok" ? "noop" : "partial");
}

// 語法校驗：patch 結果必須是合法 JS，否則放棄寫盤（磁碟保持原狀，CLI 可用）
if (!validateSyntax(original, s)) {
    writeStatus("validation-failed");
    console.log("0");
    process.exit(0);
}

const uniqueSuffix = `${process.pid}.${Date.now()}.${Math.random().toString(36).slice(2)}`;
const tmp = `${cliFile}.zh-cn-tmp.${uniqueSuffix}`;
let commitError = null;
try {
    fs.writeFileSync(tmp, s);
    const origMode = fs.statSync(cliFile).mode;
    fs.chmodSync(tmp, origMode);

    if (process.platform === "win32") {
        // NTFS 不能直接 rename 覆蓋目標；先把原檔案挪到唯一回滾位，再提交新檔案。
        const rollback = `${cliFile}.zh-cn-swap-backup.${uniqueSuffix}`;
        fs.renameSync(cliFile, rollback);
        try {
            fs.renameSync(tmp, cliFile);
        } catch (error) {
            try {
                fs.renameSync(rollback, cliFile);
            } catch {
                // rename 回滾仍失敗時用 copy 兜底，不能讓 cli.js 消失。
                fs.copyFileSync(rollback, cliFile);
                try { fs.unlinkSync(rollback); } catch {}
            }
            throw error;
        }
        try { fs.unlinkSync(rollback); } catch {}
    } else {
        // 同目錄 rename 在 POSIX 上是原子替換；併發程序最多最後一次寫入勝出。
        fs.renameSync(tmp, cliFile);
    }
} catch (error) {
    commitError = error;
} finally {
    try { fs.unlinkSync(tmp); } catch {}
}
if (commitError) {
    logEvent(`commit-failed ${cliFile}: ${commitError.message}`);
    writeStatus("error");
    console.log("0");
    process.exit(0);
}

writeStatus(residueStatus(s));
console.log(count);
