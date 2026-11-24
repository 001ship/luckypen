<#
.SYNOPSIS
    归档 PentAGI 源码，保证上游消失后还能重新构建

.DESCRIPTION
    镜像备份只冻结「运行状态」——上游停更后你手上那份会停在某个版本，加不了新功能。
    源码归档冻结的是「可重建能力」。

    本脚本：
      1. clone 上游 pentagi 源码（含完整 git 历史，便于查看版本演进）
      2. clone 本部署仓库
      3. 在归档目录写一份中文说明，标明来源、版本、日期，避免日后分不清哪个是哪个
      4. 可选打包成 zip

.PARAMETER DestDir
    归档根目录，默认 C:\pentagi-src

.PARAMETER Proxy
    git 用的 HTTP 代理。国内直连 github.com 常超时，需走本地代理

.PARAMETER Shallow
    浅克隆（--depth 1），体积小但没有历史。默认完整克隆

.PARAMETER Zip
    归档完成后打包成 zip

.EXAMPLE
    .\archive-source.ps1 -Proxy http://127.0.0.1:10090

.EXAMPLE
    .\archive-source.ps1 -DestDir D:\archive -Shallow -Zip
#>
[CmdletBinding()]
param(
    [string]$DestDir = 'C:\pentagi-src',
    [string]$Proxy = '',
    [switch]$Shallow,
    [switch]$Zip
)

$ErrorActionPreference = 'Continue'

# 确保能找到 git
$gitExe = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $gitExe) {
    foreach ($p in 'C:\Program Files\Git\cmd\git.exe', 'C:\Program Files\Git\bin\git.exe') {
        if (Test-Path $p) { $gitExe = $p; break }
    }
}
if (-not $gitExe) {
    Write-Host '[FAIL] 找不到 git。先装 Git for Windows：winget install Git.Git' -ForegroundColor Red
    exit 1
}

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

$gitArgs = @()
if ($Proxy) { $gitArgs += @('-c', "http.proxy=$Proxy", '-c', "https.proxy=$Proxy") }

Say ''
Say '=====================================================' 'Cyan'
Say '  PentAGI 源码归档' 'Cyan'
Say '=====================================================' 'Cyan'
Say ''
Say "  目标目录: $DestDir"
Say "  代理    : $(if($Proxy){$Proxy}else{'(不使用)'})"
Say "  克隆模式: $(if($Shallow){'浅克隆 (--depth 1)'}else{'完整历史'})"
Say ''

if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Force -Path $DestDir | Out-Null }

# ---------- 1. 上游源码 ----------
$upstreamDir = Join-Path $DestDir 'pentagi'
Say '[1/3] 归档上游源码 vxcontrol/pentagi' 'Cyan'

if (Test-Path (Join-Path $upstreamDir '.git')) {
    Say '  已存在，执行 fetch 拉取最新' 'Gray'
    & $gitExe @gitArgs -C $upstreamDir fetch --all --tags 2>&1 | Select-Object -Last 3 | ForEach-Object { Say "    $_" }
} else {
    $cloneArgs = @()
    if ($Shallow) { $cloneArgs += @('--depth', '1') }
    & $gitExe @gitArgs clone @cloneArgs https://github.com/vxcontrol/pentagi.git $upstreamDir 2>&1 |
        Select-Object -Last 3 | ForEach-Object { Say "    $_" }
    if ($LASTEXITCODE -ne 0) { Say '  [FAIL] 克隆失败，检查网络或代理' 'Red'; exit 1 }
}

$commit = (& $gitExe -C $upstreamDir rev-parse HEAD 2>$null)
$shortCommit = if ($commit) { $commit.Substring(0, 8) } else { 'unknown' }
$describe = (& $gitExe -C $upstreamDir describe --tags --always 2>$null)
$branch = (& $gitExe -C $upstreamDir rev-parse --abbrev-ref HEAD 2>$null)
$upstreamSize = [math]::Round(((Get-ChildItem $upstreamDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), 1)

Say "  OK  commit=$shortCommit  tag=$describe  branch=$branch  size=${upstreamSize}MB" 'Green'

# ---------- 2. 本部署仓库 ----------
$deployDir = Join-Path $DestDir 'luckypen-deploy'
Say ''
Say '[2/3] 归档部署仓库 001ship/luckypen' 'Cyan'

if (Test-Path (Join-Path $deployDir '.git')) {
    Say '  已存在，执行 fetch' 'Gray'
    & $gitExe @gitArgs -C $deployDir fetch --all 2>&1 | Select-Object -Last 2 | ForEach-Object { Say "    $_" }
} else {
    & $gitExe @gitArgs clone https://github.com/001ship/luckypen.git $deployDir 2>&1 |
        Select-Object -Last 2 | ForEach-Object { Say "    $_" }
}
$deployCommit = (& $gitExe -C $deployDir rev-parse --short HEAD 2>$null)
Say "  OK  commit=$deployCommit" 'Green'

# ---------- 3. 写归档说明 ----------
Say ''
Say '[3/3] 生成归档说明' 'Cyan'

$now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$notePath = Join-Path $DestDir '归档说明.md'

$note = @"
# PentAGI 源码归档

归档时间：$now

## 这个目录里有什么

| 目录 | 来源 | 用途 |
|---|---|---|
| ``pentagi/`` | https://github.com/vxcontrol/pentagi | PentAGI 上游源码，重建镜像用 |
| ``luckypen-deploy/`` | https://github.com/001ship/luckypen | 本项目的部署脚本与中文语言包 |

## 上游版本

- commit: ``$commit``
- tag: ``$describe``
- branch: ``$branch``
- 克隆模式: $(if($Shallow){'浅克隆（无历史）'}else{'完整历史'})

## 部署仓库版本

- commit: ``$deployCommit``

## 为什么要归档源码

Docker 镜像备份冻结的是「运行状态」：上游停更后，你手上那份镜像会永远停在
当前版本，既不能跟上游修 bug，也加不了新功能。

源码归档冻结的是「可重建能力」：只要源码在，随时可以重新构建镜像、
打补丁、改功能。

两者互补：
- 镜像在 → 立刻能跑
- 源码在 → 永远能改

## 如何用这份源码重建镜像

1. 进 ``pentagi/`` 目录，看 Dockerfile
2. 构建：``docker build -t my-pentagi:local .``
3. 在本项目 ``config/docker-compose.yml`` 里把 ``PENTAGI_IMAGE`` 指向 ``my-pentagi:local``

## 汉化层与源码的关系

本项目的汉化是**运行时 DOM 注入**（``i18n/inject.js`` + ``i18n/dict.js``），
不修改上游前端源码，因此：

- 上游升级到任何版本，汉化层都能直接叠上去
- 上游前端结构大改时，只需更新词表，不用改注入逻辑
- 归档的源码与汉化层完全解耦，互不依赖

## 目录体积说明

- 完整历史克隆约 200~400 MB
- 浅克隆（``-Shallow``）约 60~80 MB

如需分发给别人，可加 ``-Zip`` 参数打包。
"@

$note | Out-File -FilePath $notePath -Encoding utf8
Say "  OK  $notePath" 'Green'

# ---------- 4. 打包 ----------
if ($Zip) {
    Say ''
    Say '打包中...' 'Cyan'
    $zipPath = Join-Path (Split-Path $DestDir -Parent) ("pentagi-src-" + (Get-Date -Format 'yyyyMMdd') + ".zip")
    Compress-Archive -Path (Join-Path $DestDir '*') -DestinationPath $zipPath -Force
    $zipMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    Say "  OK  $zipPath  (${zipMB} MB)" 'Green'
}

# ---------- 汇总 ----------
$totalMB = [math]::Round(((Get-ChildItem $DestDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), 1)

Say ''
Say '=====================================================' 'Green'
Say '  归档完成' 'Green'
Say '=====================================================' 'Green'
Say ''
Say "  目录    : $DestDir"
Say "  总大小  : ${totalMB} MB"
Say "  上游版本: $describe ($shortCommit)"
Say "  说明文档: $notePath"
Say ''
Say '  验证归档可用性：' 'White'
Say "    git -C `"$upstreamDir`" log --oneline -3" 'Gray'
Say "    git -C `"$upstreamDir`" status" 'Gray'
Say ''
