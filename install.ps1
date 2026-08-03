#!/usr/bin/env pwsh
# claude-code-zh-cn Windows 安裝腳本 (PowerShell)
# 將中文在地化設定合併到 Claude Code 的 settings.json
# 移植自 install.sh - 適配 Windows 原生環境
# 支援 PowerShell 5.1+

param(
    [switch]$UpdateOnly = $false,
    [switch]$SkipBanner = $false
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ======== 路徑變數 ========
$ScriptDir = $PSScriptRoot
$SettingsFile = "$env:USERPROFILE\.claude\settings.json"
$OverlayFile = "$ScriptDir\settings-overlay.json"
$InstallJsonHelper = "$ScriptDir\scripts\install-json-helper.js"
$PluginSrc = "$ScriptDir\plugin"
$PluginDst = "$env:USERPROFILE\.claude\plugins\claude-code-zh-cn"
if ($env:CLAUDE_PLUGIN_ROOT) { $PluginDst = $env:CLAUDE_PLUGIN_ROOT }
$MarkerFile = "$PluginDst\.patched-version"
$SourceRepoFile = "$PluginDst\.source-repo"
$LastUpdateCheckFile = "$PluginDst\.last-update-check"
$CcSwitchConsentFile = "$PluginDst\.ccswitch-sync-consent"
$LauncherBinDir = "$env:USERPROFILE\.claude\bin"
if ($env:ZH_CN_LAUNCHER_BIN_DIR) { $LauncherBinDir = $env:ZH_CN_LAUNCHER_BIN_DIR }
$SourceRepoOverride = $env:ZH_CN_SOURCE_REPO
$CcSwitchSyncChoice = $env:ZH_CN_CCSWITCH_SYNC
$TmpDir = "$env:TEMP\claude-zh-cn"
$SupportMatrixUrl = "https://github.com/taekchef/claude-code-zh-cn/blob/main/docs/support-matrix.md"

$CliPatchStatusSummary = "已跳過（未執行 CLI Patch）"
$CliPatchStatusOk = $false
$OfficialPluginId = "claude-code-zh-cn@claude-code-zh-cn"
$OfficialMarketplaceName = "claude-code-zh-cn"
$OfficialFallbackMarker = "$PluginDst\.official-fallback-disabled"
$PluginRuntimeMode = "standalone"

# ======== 幫助函式 ========
function Write-CN {
    param([string]$Msg, [string]$Color = "White")
    Write-Host $Msg -ForegroundColor $Color
}

function write-support-window-link {
    Write-Host "  支援視窗: $SupportMatrixUrl"
}

function write-updater-boundary-note {
    Write-CN "  ! Claude Code 本體自動升級 → DISABLE_AUTOUPDATER 不歸本外掛兜底；請以 claude doctor 的 Updates 段為準" Yellow
}

function write-unpublished-window-note {
    Write-CN "  提醒：本機自驗證是臨時 patch，不等於已釋出支援；升到未釋出視窗時請先看支援視窗，未收錄就等外掛 Release 或臨時退回已驗證版本。" Yellow
}

function banner {
    if ($SkipBanner) { return }
    Write-Host ""
    if ($UpdateOnly) {
        Write-CN "=== Claude Code 中文在地化外掛 更新 ===" Blue
    } else {
        Write-CN "=== Claude Code 中文在地化外掛 安裝 ===" Blue
    }
    Write-Host ""
}

function run-js {
    param([string]$Code, [string[]]$JsArgs)
    $tmp = Join-Path $TmpDir "tmp-$PID-$((Get-Random).ToString('x')).js"
    New-Item -Force -ItemType Directory -Path $TmpDir | Out-Null
    $Code | Out-File -FilePath $tmp -Encoding ascii -NoNewline
    try {
        if ($JsArgs) {
            node $tmp @JsArgs
        } else {
            node $tmp
        }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function run-install-json-helper {
    param([string[]]$HelperArgs)
    $output = & node $InstallJsonHelper @HelperArgs
    if ($LASTEXITCODE -ne 0) {
        Write-CN "錯誤：install-json-helper 執行失敗" Red
        exit 1
    }
    return $output
}

# ======== Settings 合併腳本（單行 JS，無特殊字元） ========
$JS_BACKUP_PRUNE = "var fs=require('fs'),path=require('path');var dir=process.env.ZH_CN_SETTINGS_DIR;try{var all=fs.readdirSync(dir).filter(function(n){return n.indexOf('settings.json.zh-cn-backup.')===0}).sort();var stale=all.slice(0,Math.max(0,all.length-5));for(var i=0;i<stale.length;i++){fs.unlinkSync(path.join(dir,stale[i]))}}catch(e){}"
$JS_BUILD_OVERLAY_FILES = "var fs=require('fs');function r(f){return JSON.parse(fs.readFileSync(f,'utf8').replace(/^\uFEFF/,''))}var base=r(process.argv[2]);var verbs=r(process.argv[3]);var tips=r(process.argv[4]);base.spinnerVerbs=verbs;base.spinnerTipsOverride={excludeDefault:true,tips:(tips.tips||[]).map(function(t){return t.text})};process.stdout.write(JSON.stringify(base))"
$JS_DEEP_MERGE_FILES = "var fs=require('fs');function r(f){return JSON.parse(fs.readFileSync(f,'utf8').replace(/^\uFEFF/,''))}var sf=process.argv[2];var of=process.argv[3];function po(v){return v&&typeof v==='object'&&!Array.isArray(v)}function dm(b,o){var out={};var k;for(k in b){if(Object.prototype.hasOwnProperty.call(b,k))out[k]=b[k]}for(k in o){if(!Object.prototype.hasOwnProperty.call(o,k))continue;if(po(out[k])&&po(o[k]))out[k]=dm(out[k],o[k]);else out[k]=o[k]}return out}fs.writeFileSync(sf,JSON.stringify(dm(r(sf),r(of)),null,2)+'\n');process.stdout.write('ok')"
$JS_PATCH_REVISION = "var crypto=require('crypto'),fs=require('fs'),path=require('path');var root=process.argv[2];var files=['patch-cli.sh','patch-cli.js','cli-translations.json','bun-binary-io.js','compute-patch-revision.sh'];var hash=crypto.createHash('sha256');for(var i=0;i<files.length;i++){var f=files[i];var t=path.join(root,f);if(!fs.existsSync(t))continue;hash.update(f);hash.update('\0');hash.update(fs.readFileSync(t));hash.update('\0')}process.stdout.write(hash.digest('hex').slice(0,16))"
$JS_CCSWITCH_STATUS = "var fs=require('fs');function r(f,d){var s=fs.readFileSync(f,'utf8').replace(/^\uFEFF/,'');return s.trim()?JSON.parse(s):d}function po(v){return v&&typeof v==='object'&&!Array.isArray(v)}function vc(v){if(Array.isArray(v))return v.length;if(!po(v))return 0;if(Array.isArray(v.verbs))return v.verbs.length;return Object.keys(v).length}function tc(v){if(Array.isArray(v))return v.length;if(!po(v))return 0;if(Array.isArray(v.tips))return v.tips.length;return 0}try{var c=r(process.argv[2],{});r(process.argv[3],{});if(!po(c)){process.stdout.write('invalid');process.exit(0)}var ok=c.language==='Chinese'&&c.spinnerTipsEnabled===true&&vc(c.spinnerVerbs)>=100&&tc(c.spinnerTipsOverride)>=40;process.stdout.write(ok?'ok':'needs-sync')}catch(e){process.stdout.write('invalid')}"
$JS_CCSWITCH_MERGE = "var fs=require('fs');function r(f,d){var s=fs.readFileSync(f,'utf8').replace(/^\uFEFF/,'');return s.trim()?JSON.parse(s):d}function po(v){return v&&typeof v==='object'&&!Array.isArray(v)}function dm(b,o){var out={},k;for(k in b){if(Object.prototype.hasOwnProperty.call(b,k))out[k]=b[k]}for(k in o){if(!Object.prototype.hasOwnProperty.call(o,k))continue;if(po(out[k])&&po(o[k]))out[k]=dm(out[k],o[k]);else out[k]=o[k]}return out}var c=r(process.argv[2],{}),o=r(process.argv[3],{});if(!po(c)||!po(o))process.exit(2);fs.writeFileSync(process.argv[4],JSON.stringify(dm(c,o),null,2)+'\n')"
$JS_CCSWITCH_PROVIDER_SQL = @'
var fs=require("fs");
function fh(h){return Buffer.from(h||"","hex").toString("utf8")}
function ss(v){return "'" + String(v).replace(/'/g,"''") + "'"}
var raw=fs.readFileSync(process.argv[2],"utf8").replace(/\r/g,"");
var lines=raw.split("\n").filter(Boolean);
var updates=[];
var changed=0;
var skipped=0;
for(var i=0;i<lines.length;i++){
  var line=lines[i];
  var tab=line.indexOf("\t");
  if(tab<0){skipped++;continue}
  var id=fh(line.slice(0,tab));
  var metaText=fh(line.slice(tab+1).trim());
  var meta;
  try{meta=metaText.trim()?JSON.parse(metaText):{}}catch(e){skipped++;continue}
  if(!meta||typeof meta!=="object"||Array.isArray(meta)){skipped++;continue}
  if(meta.commonConfigEnabled!==true){changed++}
  meta.commonConfigEnabled=true;
  updates.push("update providers set meta="+ss(JSON.stringify(meta))+" where id="+ss(id)+" and app_type='claude';");
}
fs.writeFileSync(process.argv[3],updates.join("\n")+(updates.length?"\n":""));
process.stdout.write(String(changed)+" "+String(lines.length)+" "+String(skipped));
'@
$JS_RECONCILE_STANDALONE_HOOKS = @'
var fs=require("fs"),path=require("path");
var settingsFile=process.argv[2],pluginRoot=process.argv[3],mode=process.argv[4],officialPluginId=process.argv[5];
var standaloneArg="--standalone";
function object(v){return v&&typeof v==="object"&&!Array.isArray(v)}
function standalone(hook){
  if(!object(hook))return false;
  if(typeof hook.command==="string"&&hook.command.indexOf("ZH_CN_STANDALONE_HOOK=1")!==-1)return true;
  if(hook.command!=="node"||!Array.isArray(hook.args)||hook.args.indexOf(standaloneArg)===-1)return false;
  var script=String(hook.args[0]||"");
  return script===path.join(pluginRoot,"hooks","session-start.js")||script===path.join(pluginRoot,"hooks","notification.js");
}
var raw=fs.readFileSync(settingsFile,"utf8").replace(/^\uFEFF/,"");
var settings=raw.trim()?JSON.parse(raw):{};
if(!object(settings))process.exit(2);
var changed=false;
if(object(settings.hooks)){
  Object.keys(settings.hooks).forEach(function(eventName){
    var entries=settings.hooks[eventName];
    if(!Array.isArray(entries))return;
    var next=[];
    entries.forEach(function(entry){
      if(!object(entry)||!Array.isArray(entry.hooks)){next.push(entry);return}
      var hooks=entry.hooks.filter(function(hook){return !standalone(hook)});
      if(hooks.length!==entry.hooks.length)changed=true;
      if(hooks.length>0){
        if(hooks.length===entry.hooks.length)next.push(entry);
        else{var copy=Object.assign({},entry);copy.hooks=hooks;next.push(copy)}
      }
    });
    if(next.length>0)settings.hooks[eventName]=next;else delete settings.hooks[eventName];
  });
  if(Object.keys(settings.hooks).length===0)delete settings.hooks;
}
if(mode==="standalone"){
  if(!object(settings.enabledPlugins))settings.enabledPlugins={};
  settings.enabledPlugins[officialPluginId]=false;
  if(!object(settings.hooks))settings.hooks={};
  if(!Array.isArray(settings.hooks.SessionStart))settings.hooks.SessionStart=[];
  if(!Array.isArray(settings.hooks.Notification))settings.hooks.Notification=[];
  var session=path.join(pluginRoot,"hooks","session-start.js");
  var notification=path.join(pluginRoot,"hooks","notification.js");
  settings.hooks.SessionStart.push({matcher:"startup|resume|clear|compact",hooks:[{type:"command",command:"node",args:[session,standaloneArg],async:false}]});
  settings.hooks.Notification.push({matcher:"",hooks:[{type:"command",command:"node",args:[notification,standaloneArg],async:false,timeout:10}]});
  changed=true;
}
if(mode==="official-retry"){
  if(!object(settings.enabledPlugins))settings.enabledPlugins={};
  settings.enabledPlugins[officialPluginId]=true;
  changed=true;
}
if(changed)process.stdout.write(JSON.stringify(settings,null,2)+"\n");
'@

# ======== 輸出函式 ========
function completion {
    if ($UpdateOnly -or $SkipBanner) { return }
    Write-Host ""
    Write-CN "=== 安裝完成！===" Green
    Write-Host ""
    Write-CN "已啟用的功能："
    Write-CN "  √ AI 回覆語言 → 中文" Green
    Write-CN "  √ Spinner 提示 → 中文（41 條）" Green
    Write-CN "  √ Spinner 動詞 → 中文（187 個）" Green
    Write-CN "  √ 工作階段啟動 Hook → 中文上下文注入（Windows PowerShell）" Green
    Write-CN "  √ 通知 Hook → 中文翻譯（Windows PowerShell）" Green
    Write-CN "  √ 輸出風格 → Chinese" Green
    Write-CN "  √ 自動重 patch → Claude Code 更新後首次工作階段自動修復（session-start 兜底）" Green
    switch ($PluginRuntimeMode) {
        "standalone" { Write-CN "  ! 獨立備用更新 → 限時檢查 Release，工作階段結束後按提示手動更新" Yellow }
        "disabled" { Write-CN "  ! 正式外掛已停用 → 保留使用者選擇，不載入備用 Hook" Yellow }
        default { Write-CN "  √ 正式外掛更新 → 由 Claude plugin manager 管理" Green }
    }
    write-updater-boundary-note
    if ($CliPatchStatusOk) {
        Write-CN "  √ CLI Patch → $CliPatchStatusSummary" Green
    } else {
        Write-CN "  ! CLI Patch → $CliPatchStatusSummary" Yellow
    }
    write-support-window-link
    Write-Host ""
    Write-Host "重啟 Claude Code 即可生效。如需解除安裝，執行：" -NoNewline
    Write-CN ".\uninstall.ps1" Yellow
}

# ======== 依賴檢查 ========
function check-deps {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Write-CN "錯誤：需要 node，請先安裝 Node.js" Red
        exit 1
    }
    if (-not $UpdateOnly -and -not $SkipBanner) {
        if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
            Write-CN "提示：建議安裝 jq 以獲得更好的 JSON 合併支援" Yellow
            Write-Host "  winget install jqlang.jq"
        }
    }
}

# ======== 路徑/安裝偵測 ========
function find-real-claude {
    if ($env:ZH_CN_REAL_CLAUDE -and (Get-Command $env:ZH_CN_REAL_CLAUDE -ErrorAction SilentlyContinue)) {
        return $env:ZH_CN_REAL_CLAUDE
    }
    $oldPath = $env:PATH
    try {
        $filtered = ($env:PATH -split ';' | Where-Object { $_ -ne $LauncherBinDir }) -join ';'
        $env:PATH = $filtered
        $found = (Get-Command claude -ErrorAction SilentlyContinue)
        if ($found) { return $found.Source }
        return $null
    } finally {
        $env:PATH = $oldPath
    }
}

function official-marketplace-source {
    if ($SourceRepoOverride -and (
        $SourceRepoOverride -match '^(https?://|git@|ssh://)' -or
        $SourceRepoOverride -match '^[^/\\]+/[^/\\]+$'
    )) {
        return $SourceRepoOverride
    }
    return $ScriptDir
}

function official-plugin-expected-version {
    $manifest = "$PluginSrc\.claude-plugin\plugin.json"
    if (-not (Test-Path $manifest)) { return "" }
    try {
        $value = Get-Content $manifest -Raw | ConvertFrom-Json
        return [string]$value.version
    } catch {
        return ""
    }
}

function verify-official-plugin-registration {
    param([string]$ClaudeCli)
    if (-not $ClaudeCli) { return $false }

    try {
        $marketplaceOutput = & $ClaudeCli plugin marketplace list --json 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        $pluginOutput = & $ClaudeCli plugin list --json 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }

        $marketplaces = @(($marketplaceOutput -join "`n") | ConvertFrom-Json)
        $plugins = @(($pluginOutput -join "`n") | ConvertFrom-Json)
        $expectedVersion = official-plugin-expected-version
        $marketplaceOk = $false
        $pluginOk = $false
        foreach ($marketplace in $marketplaces) {
            if ($marketplace -and [string]$marketplace.name -eq $OfficialMarketplaceName) {
                $marketplaceOk = $true
            }
        }
        foreach ($plugin in $plugins) {
            if ($plugin -and
                [string]$plugin.id -eq $OfficialPluginId -and
                [string]$plugin.scope -eq "user" -and
                $plugin.enabled -eq $true -and
                (-not $expectedVersion -or [string]$plugin.version -eq $expectedVersion)) {
                $pluginOk = $true
            }
        }
        return $marketplaceOk -and $pluginOk
    } catch {
        return $false
    }
}

function official-user-plugin-installed {
    param([string]$ClaudeCli)
    if (-not $ClaudeCli) { return $false }
    try {
        $pluginOutput = & $ClaudeCli plugin list --json 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        $plugins = @(($pluginOutput -join "`n") | ConvertFrom-Json)
        foreach ($plugin in $plugins) {
            if ($plugin -and [string]$plugin.id -eq $OfficialPluginId -and [string]$plugin.scope -eq "user") {
                return $true
            }
        }
        return $false
    } catch {
        return $false
    }
}

function official-plugin-settings-state {
    if (-not (Test-Path $SettingsFile)) { return "absent" }
    try {
        $settings = Get-Content $SettingsFile -Raw | ConvertFrom-Json
        if (-not $settings -or -not $settings.enabledPlugins) { return "absent" }
        $property = $settings.enabledPlugins.PSObject.Properties[$OfficialPluginId]
        if ($null -eq $property) { return "absent" }
        if ($property.Value -eq $false) { return "disabled" }
        return "enabled"
    } catch {
        return "absent"
    }
}

function activate-standalone-fallback {
    param([string]$Reason)

    $script:PluginRuntimeMode = "standalone"
    Write-CN "官方外掛 CLI 校驗未完成（$Reason）；將停用未確認的官方入口，並啟用一套獨立備用 Hook。基礎中文設定和 CLI Patch 不受影響。" Yellow
}

function mark-official-plugin-verified {
    $script:PluginRuntimeMode = "official"
    Remove-Item $OfficialFallbackMarker -Force -ErrorAction SilentlyContinue
}

function select-safe-plugin-fallback {
    param([string]$Reason)
    $settingsState = official-plugin-settings-state

    switch ($settingsState) {
        "enabled" {
            activate-standalone-fallback $Reason
        }
        "disabled" {
            if (Test-Path $OfficialFallbackMarker) {
                activate-standalone-fallback $Reason
            } else {
                $script:PluginRuntimeMode = "disabled"
                Write-CN "官方外掛已明確停用；保留使用者選擇，不載入備用 Hook。基礎中文設定和 CLI Patch 繼續生效。" Yellow
            }
        }
        default {
            activate-standalone-fallback $Reason
        }
    }
}

function commit-settings-json-safely {
    param([string]$Json)

    $resolveCode = @'
const fs=require("fs"),path=require("path");
const file=process.argv[2];
try{process.stdout.write(fs.realpathSync(file));process.exit(0)}catch(e){}
try{const stat=fs.lstatSync(file);if(stat.isSymbolicLink()){const link=fs.readlinkSync(file);process.stdout.write(path.isAbsolute(link)?link:path.resolve(path.dirname(file),link));process.exit(0)}}catch(e){}
process.stdout.write(path.resolve(file));
'@
    $target = ((run-js $resolveCode @($SettingsFile)) | Out-String).Trim()
    if (-not $target) { throw "settings target resolution failed" }

    $directory = Split-Path -Parent $target
    New-Item -Force -ItemType Directory -Path $directory | Out-Null
    $suffix = "$PID-$((Get-Random).ToString('x'))"
    $temp = Join-Path $directory ("." + [System.IO.Path]::GetFileName($target) + ".zh-cn-hooks.$suffix.tmp")
    $rollback = Join-Path $directory ("." + [System.IO.Path]::GetFileName($target) + ".zh-cn-hooks.$suffix.rollback")
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false

    try {
        [System.IO.File]::WriteAllText($temp, $Json, $utf8NoBom)
        if (Test-Path $target) {
            # Windows ReplaceFile 保留目標檔案的 ACL，並在失敗時保留原目標。
            [System.IO.File]::Replace($temp, $target, $rollback, $true)
            Remove-Item $rollback -Force -ErrorAction SilentlyContinue
        } else {
            [System.IO.File]::Move($temp, $target)
        }
    } catch {
        if ((Test-Path $rollback) -and -not (Test-Path $target)) {
            try { [System.IO.File]::Move($rollback, $target) } catch {}
        }
        throw
    } finally {
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
    }
}

function register-official-plugin {
    $claudeCli = find-real-claude
    if (-not $claudeCli) {
        select-safe-plugin-fallback "未找到可用的 claude CLI"
        return
    }

    $initialSettingsState = official-plugin-settings-state
    if ($initialSettingsState -eq "disabled" -and (Test-Path $OfficialFallbackMarker)) {
        $script:PluginRuntimeMode = "official-retry"
        reconcile-standalone-hooks
        if ((official-plugin-settings-state) -eq "enabled") {
            $initialSettingsState = "enabled"
            Write-CN "上次因校驗失敗臨時停用了官方入口；本次重新嘗試正式外掛註冊。" Yellow
        } else {
            select-safe-plugin-fallback "無法安全切換到正式外掛重試狀態"
            return
        }
    }
    if ($initialSettingsState -eq "disabled") {
        if (Test-Path "$ScriptDir\.claude-plugin\marketplace.json") {
            $marketplaceSource = official-marketplace-source
            try { & $claudeCli plugin marketplace add --scope user $marketplaceSource *> $null } catch {}
        }
        try { & $claudeCli plugin marketplace update $OfficialMarketplaceName *> $null } catch {}
        if (official-user-plugin-installed $claudeCli) {
            try { & $claudeCli plugin update $OfficialPluginId --scope user *> $null } catch {}
        }
        $script:PluginRuntimeMode = "disabled"
        Write-CN "官方外掛已明確停用；已保留使用者選擇，不呼叫 install，也不載入備用 Hook。" Yellow
        return
    }

    if ($UpdateOnly -and (verify-official-plugin-registration $claudeCli)) {
        mark-official-plugin-verified
        Write-CN "官方外掛註冊已驗證（user scope）" Green
        return
    }

    if (-not (Test-Path "$PluginSrc\.claude-plugin\plugin.json")) {
        select-safe-plugin-fallback "安裝包缺少官方外掛清單"
        return
    }

    if (-not (Test-Path "$ScriptDir\.claude-plugin\marketplace.json")) {
        if (-not (official-user-plugin-installed $claudeCli)) {
            select-safe-plugin-fallback "安裝包缺少外掛市場清單，且未偵測到已安裝的官方外掛"
            return
        }
        try { & $claudeCli plugin marketplace update $OfficialMarketplaceName *> $null } catch {}
        try { & $claudeCli plugin update $OfficialPluginId --scope user *> $null } catch {}
        if (verify-official-plugin-registration $claudeCli) {
            mark-official-plugin-verified
            Write-CN "官方外掛註冊已驗證（user scope）" Green
        } else {
            select-safe-plugin-fallback "官方外掛自動更新後校驗失敗"
        }
        return
    }

    $marketplaceSource = official-marketplace-source
    $pluginWasInstalled = official-user-plugin-installed $claudeCli
    $pluginInstallFailed = $false
    try {
        & $claudeCli plugin marketplace add --scope user $marketplaceSource *> $null
        if ($LASTEXITCODE -ne 0) {
            if (verify-official-plugin-registration $claudeCli) {
                mark-official-plugin-verified
                Write-CN "外掛市場重新整理失敗，繼續使用已驗證的官方 user 外掛。" Yellow
            } else {
                select-safe-plugin-fallback "外掛市場註冊失敗"
            }
            return
        }
        & $claudeCli plugin marketplace update $OfficialMarketplaceName *> $null

        & $claudeCli plugin install $OfficialPluginId --scope user *> $null
        if ($LASTEXITCODE -ne 0) {
            $pluginInstallFailed = $true
            & $claudeCli plugin update $OfficialPluginId --scope user *> $null
        } elseif ($pluginWasInstalled) {
            & $claudeCli plugin update $OfficialPluginId --scope user *> $null
        }
    } catch {
        if (-not (verify-official-plugin-registration $claudeCli)) {
            select-safe-plugin-fallback "官方外掛命令執行失敗"
            return
        }
    }

    if (verify-official-plugin-registration $claudeCli) {
        mark-official-plugin-verified
        Write-CN "官方外掛註冊已驗證（user scope）" Green
    } else {
        if ($pluginInstallFailed) {
            select-safe-plugin-fallback "官方外掛安裝失敗"
        } else {
            select-safe-plugin-fallback "安裝後列表校驗失敗"
        }
    }
}

function reconcile-standalone-hooks {
    $fallbackMarkerCreated = $false
    if ($PluginRuntimeMode -eq "standalone" -and -not (Test-Path $OfficialFallbackMarker)) {
        try {
            New-Item -Force -ItemType Directory -Path $PluginDst | Out-Null
            "standalone" | Out-File -FilePath $OfficialFallbackMarker -Encoding ascii -NoNewline
            $fallbackMarkerCreated = $true
        } catch {
            $script:PluginRuntimeMode = "official-unverified"
            Write-CN "無法寫入正式外掛重試標記；為避免重複 Hook，本次不注入備用 Hook。" Yellow
        }
    }

    try {
        $reconciledJson = ((run-js $JS_RECONCILE_STANDALONE_HOOKS @($SettingsFile, $PluginDst, $PluginRuntimeMode, $OfficialPluginId)) | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "hook reconciliation failed" }
        if ($reconciledJson) {
            commit-settings-json-safely $reconciledJson
        }
        if ($PluginRuntimeMode -eq "standalone") {
            Write-CN "已啟用獨立備用 Hook（不會與官方外掛 Hook 同時載入）" Yellow
        }
    } catch {
        if ($fallbackMarkerCreated) {
            Remove-Item $OfficialFallbackMarker -Force -ErrorAction SilentlyContinue
        }
        $script:PluginRuntimeMode = "official-unverified"
        Write-CN "備用 Hook 安全寫入失敗；為避免重複 Hook，本次保留官方入口。基礎中文設定和 CLI Patch 仍保持可用。" Yellow
    }
}

function detect-install {
    param([string]$ClaudeBin)
    if (-not $ClaudeBin) { return $null }
    $helperFile = $null
    if (Test-Path "$PluginSrc\bun-binary-io.js") {
        $helperFile = "$PluginSrc\bun-binary-io.js"
    } elseif (Test-Path "$PluginDst\bun-binary-io.js") {
        $helperFile = "$PluginDst\bun-binary-io.js"
    }
    if (-not $helperFile) { return $null }
    $result = node $helperFile detect $ClaudeBin 2>$null
    if ($result) { return $result.Trim() }
    $claudeDir = Split-Path -Parent $ClaudeBin
    $cliFile = Join-Path $claudeDir "..\lib\node_modules\@anthropic-ai\claude-code\cli.js"
    $cliFile = [System.IO.Path]::GetFullPath($cliFile)
    if (Test-Path $cliFile) { return "npm:$cliFile" }
    try {
        $npmRoot = (npm root -g 2>$null).Trim()
        $cliFile2 = Join-Path $npmRoot "@anthropic-ai\claude-code\cli.js"
        if (Test-Path $cliFile2) { return "npm:$cliFile2" }
    } catch {}
    return $null
}

function detect-launcher-install {
    param([string]$ClaudeBin)
    if (-not $ClaudeBin) { return $null }
    try {
        $realPath = (Resolve-Path $ClaudeBin).ProviderPath
    } catch {
        return $null
    }

    $claudeDir = Split-Path -Parent $realPath
    $candidates = @(
        (Join-Path $claudeDir "..\lib\node_modules\@anthropic-ai\claude-code\cli.js"),
        (Join-Path $claudeDir "node_modules\@anthropic-ai\claude-code\cli.js")
    )

    foreach ($candidate in $candidates) {
        try {
            $fullPath = [System.IO.Path]::GetFullPath($candidate)
        } catch {
            $fullPath = $candidate
        }
        if (Test-Path $fullPath) { return "npm:$fullPath" }
    }

    return $null
}

# ======== Settings 操作 ========
function ensure-settings {
    if (-not (Test-Path $SettingsFile)) {
        if (-not $UpdateOnly -and -not $SkipBanner) {
            Write-CN "settings.json 不存在，建立新檔案" Yellow
        }
        $dir = Split-Path -Parent $SettingsFile
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($SettingsFile, '{}', $utf8NoBom)
    }
}

function remove-old-backups {
    $settingsDir = Split-Path -Parent $SettingsFile
    $env:ZH_CN_SETTINGS_DIR = $settingsDir
    run-js $JS_BACKUP_PRUNE
    Remove-Item Env:\ZH_CN_SETTINGS_DIR -ErrorAction SilentlyContinue
}

function build-overlay {
    if (Test-Path $InstallJsonHelper) {
        return run-install-json-helper -HelperArgs @("build-overlay", $OverlayFile, "$ScriptDir\verbs\zh-CN.json", "$ScriptDir\tips\zh-CN.json")
    }
    return run-js $JS_BUILD_OVERLAY_FILES @($OverlayFile, "$ScriptDir\verbs\zh-CN.json", "$ScriptDir\tips\zh-CN.json")
}

function merge-settings {
    ensure-settings
    if (-not $UpdateOnly) {
        $timestamp = Get-Date -Format "yyyyMMddHHmmss"
        $backupFile = "$SettingsFile.zh-cn-backup.$timestamp"
        Copy-Item $SettingsFile $backupFile
        remove-old-backups
        if (-not $SkipBanner) {
            Write-CN "已備份 settings.json -> $backupFile" Green
        }
    }
    $overlayContent = build-overlay
    $overlayTempFile = "$TmpDir\settings-overlay-$PID.json"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($overlayTempFile, $overlayContent, $utf8NoBom)
    try {
        if (Test-Path $InstallJsonHelper) {
            $mergeResult = run-install-json-helper -HelperArgs @("deep-merge-settings", $SettingsFile, $overlayTempFile)
        } else {
            $mergeResult = run-js $JS_DEEP_MERGE_FILES @($SettingsFile, $overlayTempFile)
        }
    } finally {
        Remove-Item $overlayTempFile -Force -ErrorAction SilentlyContinue
    }
    if ($mergeResult -ne "ok") {
        Write-CN "錯誤：settings.json 合併失敗" Red
        exit 1
    }
    if (-not $SkipBanner) {
        Write-CN "已更新 settings.json" Green
    }
    if ($PluginDst -and (Test-Path $PluginDst)) {
        $overlayContent | Out-File -FilePath "$PluginDst\.settings-overlay-cache.json" -Encoding utf8 -NoNewline
    }
    sync-ccswitch-common-config $overlayContent
}

function write-ccswitch-manual-steps {
    if ($SkipBanner) { return }
    Write-CN "你也可以在 CC Switch 中手動處理：編輯 Claude 供應商 -> 編輯通用配置 -> 從編輯內容提取 -> 儲存，並確認要切換的供應商勾選寫入通用配置。" Yellow
}

function get-ccswitch-consent {
    if (Test-Path $CcSwitchConsentFile) {
        return ([System.IO.File]::ReadAllText($CcSwitchConsentFile, [System.Text.Encoding]::UTF8)).Trim()
    }
    return ""
}

function set-ccswitch-consent {
    param([string]$Value)
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $CcSwitchConsentFile) | Out-Null
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($CcSwitchConsentFile, "$Value`n", $utf8NoBom)
    } catch {}
}

function ask-ccswitch-consent {
    if ($UpdateOnly -or $SkipBanner -or -not [Environment]::UserInteractive) {
        return "unavailable"
    }

    Write-Host ""
    Write-CN "偵測到你在使用 CC Switch。它切換供應商時會重寫 Claude 的 settings.json，可能覆蓋中文外掛設定。" Yellow
    Write-Host "要不要現在把中文外掛設定同步到 CC Switch 的通用配置，並讓 Claude 供應商切換時寫入通用配置？"
    Write-Host "同意後，之後切換供應商也會保留中文；不會修改 API Key、模型或供應商配置。"
    $answer = Read-Host "輸入 Y 幫我同步，或 n 自己處理 [Y/n]"

    if (-not $answer -or $answer -match '^(y|yes|Y|YES|是|好|同意)$') {
        return "allow"
    }
    return "manual"
}

function build-ccswitch-provider-update-sql {
    param(
        [string]$DbFile,
        [string]$ProvidersFile,
        [string]$ProviderSqlFile,
        [System.Text.Encoding]$Utf8NoBom
    )

    $hasProviders = sqlite3 $DbFile "select count(*) from sqlite_master where type='table' and name='providers';" 2>$null
    if ($LASTEXITCODE -ne 0 -or (($hasProviders -join "").Trim()) -ne "1") { return "" }

    $providerRows = sqlite3 $DbFile "select hex(id) || char(9) || hex(meta) from providers where app_type='claude';" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $providerRows) { return "" }

    [System.IO.File]::WriteAllText($ProvidersFile, (($providerRows -join "`n")), $Utf8NoBom)
    $summary = (run-js $JS_CCSWITCH_PROVIDER_SQL @($ProvidersFile, $ProviderSqlFile))
    if ($LASTEXITCODE -ne 0) { return "" }
    if ($summary) { return $summary.Trim() }
    return ""
}

function sync-ccswitch-common-config {
    param([string]$OverlayContent)

    $dbFile = "$env:USERPROFILE\.cc-switch\cc-switch.db"
    if (-not (Test-Path $dbFile)) { return }

    if (-not (Get-Command sqlite3 -ErrorAction SilentlyContinue)) {
        if (-not $UpdateOnly -and -not $SkipBanner) {
            Write-CN "偵測到 CC Switch，但未找到 sqlite3，無法自動檢查/同步通用配置。" Yellow
            write-ccswitch-manual-steps
        }
        return
    }

    New-Item -Force -ItemType Directory -Path $TmpDir | Out-Null
    $currentFile = Join-Path $TmpDir "ccswitch-current-$PID.json"
    $overlayFile = Join-Path $TmpDir "ccswitch-overlay-$PID.json"
    $mergedFile = Join-Path $TmpDir "ccswitch-merged-$PID.json"
    $providersFile = Join-Path $TmpDir "ccswitch-providers-$PID.tsv"
    $providerSqlFile = Join-Path $TmpDir "ccswitch-providers-$PID.sql"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false

    try {
        $currentValue = sqlite3 $dbFile "select value from settings where key='common_config_claude';" 2>$null
        if ($LASTEXITCODE -ne 0) {
            if (-not $UpdateOnly -and -not $SkipBanner) {
                Write-CN "偵測到 CC Switch，但無法讀取通用配置表，已跳過自動同步。" Yellow
            }
            return
        }

        [System.IO.File]::WriteAllText($currentFile, (($currentValue -join "`n")), $utf8NoBom)
        [System.IO.File]::WriteAllText($overlayFile, $OverlayContent, $utf8NoBom)

        $status = (run-js $JS_CCSWITCH_STATUS @($currentFile, $overlayFile))
        if ($status) { $status = $status.Trim() }

        if ($status -eq "ok") {
            $providerStatusSummary = build-ccswitch-provider-update-sql $dbFile $providersFile $providerSqlFile $utf8NoBom
            if (-not $providerStatusSummary) { return }
            $providerStatusParts = $providerStatusSummary -split ' '
            if ($providerStatusParts.Count -lt 1 -or $providerStatusParts[0] -eq "0") { return }
            $status = "needs-sync"
        }
        if ($status -ne "needs-sync") {
            if (-not $UpdateOnly -and -not $SkipBanner) {
                Write-CN "偵測到 CC Switch，但 common_config_claude 不是有效 JSON，已跳過自動同步。" Yellow
                write-ccswitch-manual-steps
            }
            return
        }

        $consent = get-ccswitch-consent
        $consentSource = ""
        if ($consent) { $consentSource = "stored" }
        if ($CcSwitchSyncChoice -match '^(1|true|TRUE|yes|YES|y|Y)$') {
            $consent = "allow"
            $consentSource = "env"
        } elseif ($CcSwitchSyncChoice -match '^(0|false|FALSE|no|NO|n|N)$') {
            $consent = "manual"
            $consentSource = "env"
        }

        if ($consent -ne "allow" -and $consent -ne "manual") {
            $consent = ask-ccswitch-consent
            if ($consent -eq "allow") {
                $consentSource = "prompt"
                set-ccswitch-consent "allow"
            } elseif ($consent -eq "manual") {
                $consentSource = "prompt"
                set-ccswitch-consent "manual"
            } else {
                if (-not $UpdateOnly -and -not $SkipBanner) {
                    Write-CN "偵測到 CC Switch 通用配置缺少中文設定；目前不是互動式安裝，未自動修改。" Yellow
                    Write-CN "如需授權自動同步，可執行：`$env:ZH_CN_CCSWITCH_SYNC='1'; .\install.ps1" Yellow
                    write-ccswitch-manual-steps
                }
                return
            }
        }

        if ($consent -ne "allow") {
            if ($consentSource -eq "prompt" -and -not $SkipBanner) {
                write-ccswitch-manual-steps
            }
            return
        }

        set-ccswitch-consent "allow"
        run-js $JS_CCSWITCH_MERGE @($currentFile, $overlayFile, $mergedFile) | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $mergedFile)) {
            if (-not $SkipBanner) {
                Write-CN "CC Switch 通用配置合併失敗，已跳過自動同步。" Yellow
                write-ccswitch-manual-steps
            }
            return
        }

        $timestamp = Get-Date -Format "yyyyMMddHHmmss"
        $backupFile = "$dbFile.zh-cn-backup.$timestamp"
        try { Copy-Item $dbFile $backupFile -Force } catch { $backupFile = "" }

        $providerUpdateSql = ""
        $providerSyncSummary = build-ccswitch-provider-update-sql $dbFile $providersFile $providerSqlFile $utf8NoBom
        if ($providerSyncSummary -and (Test-Path $providerSqlFile)) {
            $providerUpdateSql = [System.IO.File]::ReadAllText($providerSqlFile, [System.Text.Encoding]::UTF8)
        }

        $sqlPath = $mergedFile.Replace('\', '/').Replace("'", "''")
        $sql = "begin immediate; insert or replace into settings(key,value) values('common_config_claude', CAST(readfile('$sqlPath') AS TEXT)); delete from settings where key='common_config_claude_cleared'; $providerUpdateSql commit;"
        sqlite3 $dbFile $sql | Out-Null
        if ($LASTEXITCODE -eq 0) {
            if (-not $SkipBanner) {
                Write-CN "已在使用者同意後同步 CC Switch 通用配置" Green
                if ($providerSyncSummary) {
                    $providerParts = $providerSyncSummary -split ' '
                    if ($providerParts.Count -ge 3 -and $providerParts[1] -ne "0") {
                        Write-CN "已讓 CC Switch 的 Claude 供應商切換時寫入通用配置（$($providerParts[0])/$($providerParts[1]) 個需要更新）" Green
                    }
                    if ($providerParts.Count -ge 3 -and $providerParts[2] -ne "0") {
                        Write-CN "有 $($providerParts[2]) 個 Claude 供應商 meta 不是有效 JSON，已跳過。" Yellow
                    }
                }
                if ($backupFile) { Write-CN "已備份 CC Switch 資料庫 -> $backupFile" Green }
            }
        } else {
            if (-not $SkipBanner) {
                Write-CN "CC Switch 資料庫目前無法寫入，已跳過自動同步。" Yellow
                if ($backupFile) { Write-CN "同步前備份已保留：$backupFile" Yellow }
                write-ccswitch-manual-steps
            }
        }
    } finally {
        Remove-Item $currentFile, $overlayFile, $mergedFile, $providersFile, $providerSqlFile -Force -ErrorAction SilentlyContinue
    }
}

# ======== 外掛同步 ========
function sync-plugin {
    if (-not $PluginDst -or $PluginDst -eq "\" -or $PluginDst -eq "/") {
        Write-CN "錯誤：PLUGIN_DST 非法，拒絕同步" Red
        exit 1
    }
    if (Test-Path $PluginDst) {
        Get-ChildItem $PluginDst -ErrorAction SilentlyContinue | Where-Object {
            -not $_.Name.StartsWith('.')
        } | Remove-Item -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $PluginDst | Out-Null
    Copy-Item "$PluginSrc\*" -Destination $PluginDst -Recurse -Force

    $dstHooksJson = "$PluginDst\hooks.json"
    if (Test-Path $dstHooksJson) {
        $hooksContent = [System.IO.File]::ReadAllText($dstHooksJson, [System.Text.Encoding]::UTF8)
        $hooksContent = $hooksContent -replace "/hooks/session-start'", "/hooks/session-start.cmd'"
        $hooksContent = $hooksContent -replace "/hooks/notification'", "/hooks/notification.cmd'"
        $hooksContent | Out-File -FilePath $dstHooksJson -Encoding ascii -NoNewline
    }
    if (-not $SkipBanner) {
        Write-CN "已安裝外掛 -> $PluginDst" Green
    }
}

# ======== Launcher 安裝 ========
function remove-launcher-file {
    param([string]$Target)
    if (-not (Test-Path $Target)) { return }

    $content = ""
    try {
        $content = [System.IO.File]::ReadAllText($Target, [System.Text.Encoding]::UTF8)
    } catch {}

    if ($content -match "claude-code-zh-cn") {
        Remove-Item $Target -Force -ErrorAction SilentlyContinue
        return $true
    } elseif (-not $SkipBanner) {
        Write-CN "偵測到自訂 launcher，未自動刪除：$Target" Yellow
    }
    return $false
}

function remove-launcher-artifacts {
    $removedCmd = remove-launcher-file "$LauncherBinDir\claude.cmd"
    $removedPs1 = remove-launcher-file "$LauncherBinDir\claude.ps1"

    $remaining = @()
    if (Test-Path $LauncherBinDir) {
        $remaining = @(Get-ChildItem $LauncherBinDir -ErrorAction SilentlyContinue)
        if (-not $remaining) {
            Remove-Item $LauncherBinDir -Force -ErrorAction SilentlyContinue
        }
    }

    if ($remaining -and -not $SkipBanner -and ($removedCmd -or $removedPs1)) {
        Write-CN "launcher 目錄還有其他檔案，未移除 PATH：$LauncherBinDir" Yellow
    }

    if (-not $remaining -and $env:ZH_CN_SKIP_USER_PATH_UPDATE -ne "1") {
        $currentUserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
        if ($currentUserPath -like "*$LauncherBinDir*") {
            $newPath = ($currentUserPath -split ';' | Where-Object {
                $_ -ne $LauncherBinDir -and $_ -ne "$LauncherBinDir\"
            }) -join ';'
            [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        }
    }
}

function install-launcher {
    $realClaude = find-real-claude
    $installInfo = detect-launcher-install $realClaude
    $kind = ""
    if ($installInfo) {
        $kind = ($installInfo -split ':', 2)[0]
    }

    if ($kind -ne "npm") {
        remove-launcher-artifacts
        if (-not $SkipBanner) {
            Write-CN "目前安裝方式不是 npm cli.js，已跳過 launcher PATH 注入" Yellow
        }
        return
    }

    if (-not (Test-Path "$PluginSrc\bin\claude-launcher.cmd")) {
        if (-not $SkipBanner) {
            Write-CN "launcher 檔案缺失，已跳過 PATH 注入" Yellow
        }
        return
    }
    New-Item -ItemType Directory -Force -Path $LauncherBinDir | Out-Null
    Copy-Item "$PluginSrc\bin\claude-launcher.ps1" "$LauncherBinDir\claude.ps1" -Force
    Copy-Item "$PluginSrc\bin\claude-launcher.cmd" "$LauncherBinDir\claude.cmd" -Force

    $currentUserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($env:ZH_CN_SKIP_USER_PATH_UPDATE -eq "1") {
        if (-not $SkipBanner) {
            Write-CN "測試模式：已跳過使用者 PATH 持久化寫入" Yellow
        }
    } elseif ($currentUserPath -notlike "*$LauncherBinDir*") {
        $newPath = $LauncherBinDir
        if ($currentUserPath) { $newPath = "$LauncherBinDir;$currentUserPath" }
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        if (-not $SkipBanner) {
            Write-CN "已將 launcher 目錄加入使用者 PATH -> $LauncherBinDir" Green
        }
    }
    if (-not $SkipBanner) {
        Write-CN "已安裝 Windows launcher -> $LauncherBinDir" Green
    }
}

# ======== CLI Patch ========
function get-patch-revision {
    param([string]$Root)
    if (Test-Path $InstallJsonHelper) {
        run-install-json-helper -HelperArgs @("patch-revision", $Root)
    } else {
        run-js $JS_PATCH_REVISION @($Root)
    }
}

function read-cli-version {
    param([string]$CliFile)
    if (-not (Test-Path $CliFile)) { return "" }
    try {
        foreach ($line in (Get-Content $CliFile -First 10)) {
            if ($line -match '^// Version: (.+)$') {
                return $matches[1]
            }
        }
        return ""
    } catch {
        return ""
    }
}

function patch-npm-cli {
    param([string]$CliFile)
    Write-Host ""
    Write-CN "正在 patch cli.js 硬編碼文字..." Blue
    $currentVersion = read-cli-version $CliFile
    $backupFile = "$CliFile.zh-cn-backup"
    $patchScript = Join-Path $PluginSrc "patch-cli.js"
    $translationsFile = Join-Path $PluginSrc "cli-translations.json"
    if (-not (Test-Path $patchScript)) { return }

    # 備份/恢復/語法校驗/失敗回滾統一由 patch-cli.js 託管（--backup 模式）
    $statusFile = Join-Path ([System.IO.Path]::GetTempPath()) ("cczh-patch-status-" + [System.IO.Path]::GetRandomFileName())
    $patchCount = node $patchScript $CliFile $translationsFile --backup $backupFile --status $statusFile 2>$null
    $patchStatus = "error"
    if (Test-Path $statusFile) {
        $patchStatus = (Get-Content $statusFile -Raw).Trim()
        Remove-Item $statusFile -Force -ErrorAction SilentlyContinue
    }

    switch ($patchStatus) {
        "ok" {
            Write-CN "已 patch cli.js（${patchCount} 處硬編碼文字）" Green
            $script:CliPatchStatusSummary = "cli.js 中文化（${patchCount} 處硬編碼文字）"
            $script:CliPatchStatusOk = $true
        }
        "partial" {
            Write-CN "已 patch cli.js（${patchCount} 處），但目前版本存在未覆蓋的英文文案（部分降級，CLI 可正常使用）" Yellow
            $script:CliPatchStatusSummary = "cli.js 部分中文化（${patchCount} 處，目前版本存在未覆蓋文案）"
            $script:CliPatchStatusOk = $true
        }
        "noop" {
            Write-CN "cli.js 無新增改動（可能已是最新狀態）" Green
            $script:CliPatchStatusSummary = "cli.js 無新增改動（可能已是最新狀態）"
            $script:CliPatchStatusOk = $true
        }
        "validation-failed" {
            Write-CN "patch 結果未通過 JS 語法校驗，已放棄寫入（CLI 保持英文可用，詳見外掛目錄 patch.log）" Yellow
            $script:CliPatchStatusSummary = "已跳過（patch 結果未通過語法校驗，CLI 保持英文可用）"
            return
        }
        default {
            Write-CN "CLI Patch 未完成（詳見外掛目錄 patch.log），CLI 保持原樣可用" Yellow
            $script:CliPatchStatusSummary = "已跳過（CLI Patch 未完成，詳見 patch.log）"
            return
        }
    }

    $patchRevision = get-patch-revision $PluginDst
    if ($patchRevision -and $currentVersion) {
        "${currentVersion}|${patchRevision}" | Out-File -FilePath $MarkerFile -Encoding ascii -NoNewline
    }
}

function get-support-window {
    $supportFile = "$PluginDst\support-window.json"
    if (-not (Test-Path $supportFile)) {
        $supportFile = "$PluginSrc\support-window.json"
    }
    if (-not (Test-Path $supportFile)) { return $null }
    try {
        return Get-Content $supportFile -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function compare-version {
    param([string]$Left, [string]$Right)
    $leftParts = @($Left -split '\.' | ForEach-Object {
        $n = 0
        if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 }
    })
    $rightParts = @($Right -split '\.' | ForEach-Object {
        $n = 0
        if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 }
    })
    $max = [Math]::Max($leftParts.Count, $rightParts.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $l = if ($i -lt $leftParts.Count) { $leftParts[$i] } else { 0 }
        $r = if ($i -lt $rightParts.Count) { $rightParts[$i] } else { 0 }
        if ($l -gt $r) { return 1 }
        if ($l -lt $r) { return -1 }
    }
    return 0
}

function test-version-in-entry {
    param($Entry, [string]$Version)
    if (-not $Entry -or -not $Version) { return $false }
    if ($Entry.versions) {
        foreach ($item in @($Entry.versions)) {
            if ([string]$item -eq $Version) { return $true }
        }
    }
    return $false
}

function is-supported-windows-native-version {
    param([string]$Version)
    $support = get-support-window
    if (-not $support -or -not $support.windowsNativeExperimental) { return $false }
    return test-version-in-entry $support.windowsNativeExperimental $Version
}

function can-try-provisional-windows-native-version {
    param([string]$Version)
    if (-not $Version) { return $false }
    $support = get-support-window
    $entry = $support.windowsNativeExperimental
    if (-not $entry -or -not $entry.floor) { return $false }
    if ($entry.platform -and [string]$entry.platform -ne "win32-x64") { return $false }
    return (compare-version $Version ([string]$entry.floor)) -ge 0
}

function get-native-version-from-execution {
    param([string]$BinaryPath)
    $versionHome = Join-Path $TmpDir "cczh-version-home-$PID"
    $oldUserProfile = $env:USERPROFILE
    $oldAppData = $env:APPDATA
    $oldLocalAppData = $env:LOCALAPPDATA
    try {
        New-Item -Force -ItemType Directory -Path $versionHome | Out-Null
        $env:USERPROFILE = $versionHome
        $env:APPDATA = Join-Path $versionHome "AppData\Roaming"
        $env:LOCALAPPDATA = Join-Path $versionHome "AppData\Local"
        New-Item -Force -ItemType Directory -Path $env:APPDATA, $env:LOCALAPPDATA | Out-Null
        $output = & $BinaryPath --version 2>$null
        $text = [string]($output -join "`n")
        $match = [regex]::Match($text, '[0-9]+\.[0-9]+\.[0-9]+')
        if ($match.Success) { return $match.Value }
        return ""
    } catch {
        return ""
    } finally {
        $env:USERPROFILE = $oldUserProfile
        $env:APPDATA = $oldAppData
        $env:LOCALAPPDATA = $oldLocalAppData
        Remove-Item $versionHome -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function patch-native-bun {
    param([string]$BinaryPath)
    $helper = "$PluginDst\bun-binary-io.js"
    if (-not (Test-Path $helper)) {
        $helper = "$PluginSrc\bun-binary-io.js"
    }
    if (-not (Test-Path $helper)) {
        Write-CN "原生二進位制 patch helper 缺失，已跳過 CLI Patch" Yellow
        write-support-window-link
        $script:CliPatchStatusSummary = "已跳過（原生二進位制 helper 缺失）"
        return
    }

    Write-Host ""
    Write-CN "偵測到 Windows 原生二進位制安裝" Blue
    Write-Host "  二進位制路徑: $BinaryPath"

    $currentVersion = (node $helper version $BinaryPath 2>$null)
    if ($currentVersion) { $currentVersion = $currentVersion.Trim() }

    $patchMode = "verified"
    if (is-supported-windows-native-version $currentVersion) {
        $patchMode = "verified"
    } elseif (can-try-provisional-windows-native-version $currentVersion) {
        $patchMode = "provisional"
    } else {
        $displayVersion = $currentVersion
        if (-not $displayVersion) { $displayVersion = "unknown" }
        Write-CN "目前 Windows 原生二進位制版本 $displayVersion 暫不支援 CLI Patch，已跳過 CLI Patch（安全離開）" Yellow
        write-support-window-link
        write-updater-boundary-note
        Write-CN "  下一步：如果是 Claude Code 自動升到未釋出視窗，請等外掛釋出支援，或臨時安裝支援視窗內版本。" Yellow
        $script:CliPatchStatusSummary = "已跳過（Windows 原生二進位制版本 $displayVersion 暫不支援 CLI Patch）"
        return
    }

    if ($patchMode -eq "provisional") {
        Write-Host "  版本: $currentVersion（未納入已釋出支援視窗，安裝時本機自驗證）"
        write-support-window-link
        write-unpublished-window-note
    } else {
        Write-Host "  版本: $currentVersion（已驗證）"
    }

    $depStatus = (node $helper check-deps 2>$null)
    if (-not $depStatus -or $depStatus.Trim() -ne "ok") {
        Write-CN "需要安裝 node-lief 來支援 Windows native patch" Yellow
        Write-Host "  執行: npm install -g node-lief"
        Write-Host "  然後重新執行 install.ps1"
        write-support-window-link
        $script:CliPatchStatusSummary = "已跳過（Windows native CLI Patch 需要 node-lief）"
        return
    }

    $tmpJs = Join-Path $TmpDir "claude-zh-cn-extract-$PID.js"
    $backupFile = "$BinaryPath.zh-cn-backup"
    New-Item -Force -ItemType Directory -Path $TmpDir | Out-Null

    $backupVersion = ""
    if (Test-Path $backupFile) {
        $backupVersion = (node $helper version $backupFile 2>$null)
        if ($backupVersion) { $backupVersion = $backupVersion.Trim() }
    }

    if ((Test-Path $backupFile) -and $currentVersion -and $backupVersion -eq $currentVersion) {
        Copy-Item $backupFile $BinaryPath -Force
        Write-CN "已從備份恢復原始原生二進位制（版本一致: $currentVersion）" Green
    } else {
        Copy-Item $BinaryPath $backupFile -Force
        Write-CN "已備份原生二進位制（版本: $currentVersion）" Green
    }

    $sourceHash = (node $helper hash $BinaryPath 2>$null)
    if ($sourceHash) { $sourceHash = $sourceHash.Trim() }
    if (-not $sourceHash) { $sourceHash = "unknown" }

    try {
        node $helper extract $BinaryPath $tmpJs | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "extract failed" }

        $patchScript = Join-Path $PluginDst "patch-cli.js"
        $translationsFile = Join-Path $PluginDst "cli-translations.json"
        $patchCount = node $patchScript $tmpJs $translationsFile 2>$null
        if ($LASTEXITCODE -ne 0) { throw "patch-cli failed" }
        if (-not $patchCount) { $patchCount = "0" }

        if ([int]$patchCount -gt 0) {
            node $helper repack $BinaryPath $tmpJs | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "repack failed" }
            Write-Host "  正在執行 --version 做啟動自檢..."
            $verifiedVersion = get-native-version-from-execution $BinaryPath
            if ($verifiedVersion -ne $currentVersion) { throw "self verification failed" }
            if ($patchMode -eq "provisional") {
                Write-CN "本機自驗證通過，已 patch Windows 原生二進位制（${patchCount} 處硬編碼文字）" Green
                $script:CliPatchStatusSummary = "Windows native 本機自驗證中文化（${patchCount} 處硬編碼文字，未納入已釋出支援視窗）"
            } else {
                Write-CN "已 patch Windows 原生二進位制（${patchCount} 處硬編碼文字）" Green
                $script:CliPatchStatusSummary = "Windows native 中文化（${patchCount} 處硬編碼文字）"
            }
            $script:CliPatchStatusOk = $true
        } else {
            Write-CN "Windows 原生二進位制無新增改動（可能已是最新狀態）" Yellow
            if ($patchMode -eq "provisional") {
                $script:CliPatchStatusSummary = "已跳過（Windows 原生二進位制本機自驗證未找到可 patch 內容）"
                write-support-window-link
                return
            } else {
                $script:CliPatchStatusSummary = "Windows native 無新增改動（可能已是最新狀態）"
                $script:CliPatchStatusOk = $true
            }
        }
    } catch {
        Write-CN "Windows 原生二進位制 patch 失敗，正在從備份恢復..." Red
        if (Test-Path $backupFile) {
            Copy-Item $backupFile $BinaryPath -Force -ErrorAction SilentlyContinue
        }
        write-support-window-link
        $script:CliPatchStatusSummary = "已跳過（Windows 原生二進位制 patch 失敗）"
        return
    } finally {
        Remove-Item $tmpJs -Force -ErrorAction SilentlyContinue
    }

    $patchRevision = get-patch-revision $PluginDst
    $finalHash = (node $helper hash $BinaryPath 2>$null)
    if ($finalHash) { $finalHash = $finalHash.Trim() }
    if ($patchRevision -and $currentVersion) {
        if (-not $finalHash) { $finalHash = "unknown" }
        if ($patchMode -eq "provisional") {
            "native|${currentVersion}|${finalHash}|${patchRevision}|provisional|win32-x64|${sourceHash}" | Out-File -FilePath $MarkerFile -Encoding ascii -NoNewline
        } else {
            "native|${currentVersion}|${finalHash}|${patchRevision}" | Out-File -FilePath $MarkerFile -Encoding ascii -NoNewline
        }
    }
}

function initial-patch {
    $realClaude = find-real-claude
    if (-not $realClaude) {
        Write-CN "未找到 Claude Code，跳過 patch 步驟" Yellow
        $script:CliPatchStatusSummary = "已跳過（未偵測到 Claude Code）"
        return
    }
    $installInfo = detect-install $realClaude
    if (-not $installInfo) {
        Write-CN "未找到 Claude Code，跳過 patch 步驟" Yellow
        $script:CliPatchStatusSummary = "已跳過（未偵測到 Claude Code）"
        return
    }
    $kind, $target = $installInfo -split ':', 2
    switch ($kind) {
        "npm" {
            if ($target -and (Test-Path $target)) {
                patch-npm-cli $target
            }
        }
        "native-bun" {
            if ($target -and (Test-Path $target)) {
                patch-native-bun $target
            }
        }
        "unknown" {
            Write-CN "目前安裝方式暫不支援 CLI Patch，已跳過此步驟" Yellow
            $script:CliPatchStatusSummary = "已跳過（目前安裝方式暫不支援 CLI Patch）"
        }
        default {
            Write-CN "未識別的安裝型別: $kind" Yellow
            $script:CliPatchStatusSummary = "已跳過（未識別的安裝型別: $kind）"
        }
    }
}

# ======== 後設資料寫入 ========
function write-metadata {
    $sourceRepo = ""
    if ($SourceRepoOverride) {
        $sourceRepo = $SourceRepoOverride
    } elseif ($UpdateOnly -and (Test-Path $SourceRepoFile)) {
        $sourceRepo = [System.IO.File]::ReadAllText($SourceRepoFile, [System.Text.Encoding]::UTF8).Trim()
    } elseif (-not $UpdateOnly) {
        $sourceRepo = $ScriptDir
    }
    if ($sourceRepo) {
        "$sourceRepo" | Out-File -FilePath $SourceRepoFile -Encoding ascii -NoNewline
    }
    $timestamp = [int][double]::Parse((Get-Date (Get-Date).ToUniversalTime() -UFormat %s))
    "$timestamp" | Out-File -FilePath $LastUpdateCheckFile -Encoding ascii -NoNewline
}

# ======== 主流程 ========
function Main {
    banner
    check-deps
    sync-plugin
    register-official-plugin
    install-launcher
    merge-settings
    reconcile-standalone-hooks
    write-metadata
    if (-not $UpdateOnly) {
        initial-patch
    }
    completion
}

Main
