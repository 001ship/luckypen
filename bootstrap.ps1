<#
.SYNOPSIS
    lucky自动化工具 · 一键远程安装引导

.DESCRIPTION
    不依赖 git，直接下载仓库快照并调用 install.ps1。
    适合「把一条链接丢给 agent / 用户」的场景。

.EXAMPLE
    # 联网一行装（会自动提权）
    irm https://raw.githubusercontent.com/001ship/luckypen/main/bootstrap.ps1 | iex

.EXAMPLE
    # 带 LLM Key
    $env:LUCKY_DEEPSEEK_KEY='sk-xxx'
    irm https://raw.githubusercontent.com/001ship/luckypen/main/bootstrap.ps1 | iex

.EXAMPLE
    # 下载后本地跑（更好排查）
    curl.exe -L -o bootstrap.ps1 https://raw.githubusercontent.com/001ship/luckypen/main/bootstrap.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\pentagi',
    [switch]$NoReboot
)

$ErrorActionPreference = 'Stop'
$RepoZip = 'https://github.com/001ship/luckypen/archive/refs/heads/main.zip'
$Work = Join-Path $env:TEMP ('luckypen-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

Say ''
Say '=====================================================' 'Cyan'
Say '  lucky自动化工具 · 一键安装引导' 'Cyan'
Say '=====================================================' 'Cyan'
Say ''

# ---------- 提权 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Say '需要管理员权限，正在提权...' 'Yellow'
    # 提权后重跑一个「引导自身」：先下载脚本到临时文件再以管理员运行
    $selfPath = Join-Path $env:TEMP 'luckypen-bootstrap-run.ps1'
    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        Copy-Item $PSCommandPath $selfPath -Force
    } else {
        # 通过 irm|iex 运行时没有脚本路径，重新拉一份
        Invoke-WebRequest 'https://raw.githubusercontent.com/001ship/luckypen/main/bootstrap.ps1' -OutFile $selfPath -UseBasicParsing
    }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$selfPath`"", '-InstallDir', "`"$InstallDir`"")
    if ($NoReboot) { $argList += '-NoReboot' }
    $p = Start-Process powershell.exe -Verb RunAs -PassThru -Wait -ArgumentList $argList
    exit $p.ExitCode
}

# ---------- 环境预检 ----------
Say '环境预检：' 'Cyan'
$build = [Environment]::OSVersion.Version.Build
Say "  Windows build : $build"
if ($build -lt 22000) {
    Say '  ✗ 需要 Windows 11 (build 22000+) 或 Win10 21H2+' 'Red'
    exit 1
}
$freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
Say "  磁盘可用      : $freeGB GB"
if ($freeGB -lt 20) {
    Say '  ✗ 至少需要 20 GB 空闲磁盘' 'Red'
    exit 1
}
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
Say "  内存          : $ramGB GB"
if ($ramGB -lt 8) {
    Say '  ! 内存低于 8 GB，可能不稳定' 'Yellow'
}
Say '  ✓ 预检通过' 'Green'
Say ''

# ---------- 下载仓库 ----------
Say "下载安装包..." 'Cyan'
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$zip = Join-Path $Work 'repo.zip'

$ok = $false
for ($i = 1; $i -le 4; $i++) {
    try {
        Invoke-WebRequest -Uri $RepoZip -OutFile $zip -UseBasicParsing -TimeoutSec 300
        $ok = $true
        break
    } catch {
        Say "  第 $i 次下载失败：$($_.Exception.Message)" 'Yellow'
        Start-Sleep -Seconds ($i * 3)
    }
}
if (-not $ok) { Say '  ✗ 下载失败，请检查网络后重试' 'Red'; exit 1 }

$size = [math]::Round((Get-Item $zip).Length / 1KB, 1)
Say "  ✓ 已下载 $size KB" 'Green'

Say '解压...' 'Cyan'
Expand-Archive -Path $zip -DestinationPath $Work -Force
$root = Get-ChildItem $Work -Directory | Where-Object { $_.Name -like 'luckypen-*' } | Select-Object -First 1
if (-not $root) { $root = Get-ChildItem $Work -Directory | Select-Object -First 1 }
if (-not $root) { Say '  ✗ 解压后找不到目录' 'Red'; exit 1 }

$installer = Join-Path $root.FullName 'install.ps1'
if (-not (Test-Path $installer)) { Say "  ✗ 缺少 install.ps1" 'Red'; exit 1 }
Say "  ✓ 安装脚本: $installer" 'Green'
Say ''

# ---------- 调用安装 ----------
$installArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$installer`"",
                 '-InstallDir', "`"$InstallDir`"", '-Yes')
if ($NoReboot) { $installArgs += '-NoReboot' }

# 支持从环境变量预置 LLM Key
$key = $env:LUCKY_DEEPSEEK_KEY
if ($key) {
    $installArgs += @('-DeepSeekKey', $key)
    Say '  已从环境变量 LUCKY_DEEPSEEK_KEY 读取 LLM 密钥' 'Gray'
} else {
    Say '  未提供 LLM 密钥，安装后可编辑 .env 补填' 'Gray'
}
Say ''

Say '开始安装（阶段 1）...' 'Cyan'
$code = 0
& powershell.exe @installArgs
$code = $LASTEXITCODE

Say ''
if ($code -eq 0) {
    Say '=====================================================' 'Green'
    Say '  阶段 1 完成' 'Green'
    Say '=====================================================' 'Green'
    Say ''
    if ($NoReboot) {
        Say '  已跳过重启。重启后安装会自动继续。' 'Yellow'
    } else {
        Say '  机器将在 60 秒内重启，重启后自动继续安装。' 'Yellow'
        Say '  重启完成后约 20~40 分钟可访问 https://127.0.0.1:8443' 'Gray'
    }
    Say ''
    Say "  安装目录: $InstallDir" 'Gray'
    Say "  日志    : $(Join-Path $InstallDir 'install.log')" 'Gray'
    Say "  状态文件: $(Join-Path $InstallDir 'install-state.json')（阶段 2 完成后生成）" 'Gray'
} else {
    Say "安装脚本返回 $code，请查看日志：" 'Red'
    Say "  $(Join-Path $InstallDir 'install.log')" 'Gray'
}
Say ''
