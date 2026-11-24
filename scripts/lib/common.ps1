# 公共函数：日志、重试、提权、WSL 调用
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if (-not $env:PENTAGI_LOG) {
    $env:PENTAGI_LOG = Join-Path $env:TEMP 'pentagi-install.log'
}

function Write-Stamp { param([string]$Level, [string]$Message)
    $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } 'STEP' { 'Cyan' } default { 'Gray' } }
    $line = "[{0}] [{1,-4}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line -ForegroundColor $color
    try { Add-Content -LiteralPath $env:PENTAGI_LOG -Value $line -Encoding utf8 } catch { }
}

function Step { param([string]$M) Write-Stamp 'STEP' $M }
function Ok   { param([string]$M) Write-Stamp 'OK'   $M }
function Warn { param([string]$M) Write-Stamp 'WARN' $M }
function Fail { param([string]$M) Write-Stamp 'FAIL' $M }
function Info { param([string]$M) Write-Stamp 'INFO' $M }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 以管理员身份重跑当前脚本
function Invoke-Elevated {
    param([string]$ScriptPath, [string[]]$Arguments = @())
    if (Test-Admin) { return $false }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"") + $Arguments
    Step '需要管理员权限，正在提权...'
    $p = Start-Process powershell.exe -Verb RunAs -PassThru -Wait -ArgumentList $argList
    exit $p.ExitCode
}

function Get-RandomHex {
    param([int]$Bytes = 16)
    $buf = New-Object byte[] $Bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
    return ($buf | ForEach-Object { $_.ToString('x2') }) -join ''
}

# 带指数退避的重试
function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Name = 'operation',
        [int]$MaxAttempts = 4,
        [int]$BaseDelaySec = 3
    )
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            & $Action
            if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "exit code $LASTEXITCODE" }
            return $true
        } catch {
            $msg = $_.Exception.Message
            if ($i -eq $MaxAttempts) { Fail "$Name 失败（$i/$MaxAttempts）：$msg"; return $false }
            $delay = $BaseDelaySec * $i
            Warn "$Name 第 $i 次失败：$msg；${delay}s 后重试"
            Start-Sleep -Seconds $delay
        }
    }
}

# 在指定 WSL 发行版里执行 bash 脚本文件（base64 传输，规避编码与引号问题）
function Invoke-WslScript {
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$ScriptArgs = @(),
        [switch]$AsRoot,
        [int]$TimeoutSec = 0
    )
    if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "脚本不存在: $ScriptPath" }
    $raw = Get-Content -LiteralPath $ScriptPath -Raw -Encoding utf8
    $norm = $raw -replace "`r`n", "`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($norm))

    $argStr = ($ScriptArgs | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '
    $inner = "echo '$b64' | base64 -d > /tmp/_step.sh && chmod +x /tmp/_step.sh && bash /tmp/_step.sh $argStr"

    $args = @('-d', $Distro, '--cd', '/root')
    if ($AsRoot) { $args += @('-u', 'root') }
    $args += @('--', 'bash', '-lc', $inner)

    $out = & wsl.exe @args 2>&1
    $rc = $LASTEXITCODE
    return @{ rc = $rc; out = ($out | ForEach-Object { "$_" }) }
}

function Test-WslReady {
    param([string]$Distro)
    $null = & wsl.exe --status 2>&1
    if ($LASTEXITCODE -ne 0) { return $false }
    if ($Distro) {
        $null = & wsl.exe -d $Distro -- true 2>&1
        return ($LASTEXITCODE -eq 0)
    }
    return $true
}

function Get-WslDistros {
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path $lxss)) { return @() }
    return @(Get-ChildItem $lxss -ErrorAction SilentlyContinue | ForEach-Object {
        (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DistributionName
    } | Where-Object { $_ })
}

function Get-WslIp {
    param([string]$Distro)
    $raw = & wsl.exe -d $Distro -u root -- hostname -I 2>&1
    return (($raw -join ' ').Trim().Split(' ') | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1)
}

# 用 curl 下载，失败自动重试；curl 比 Invoke-WebRequest 更稳且显示进度
function Get-FileWithRetry {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$MaxAttempts = 4
    )
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        Info "下载 $(Split-Path -Leaf $OutFile)（第 $i/$MaxAttempts 次）"
        & curl.exe -fL --retry 3 --retry-delay 2 --retry-all-errors -C - -o $OutFile $Url 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $OutFile) -and (Get-Item -LiteralPath $OutFile).Length -gt 1024) {
            Ok "已下载 $((Get-Item -LiteralPath $OutFile).Length / 1MB -as [int]) MB"
            return $true
        }
        Warn "下载失败（rc=$LASTEXITCODE），$([int]($i*3))s 后重试"
        Start-Sleep -Seconds ([int]($i * 3))
    }
    return $false
}

function Assert-Command {
    param([string]$Name, [string]$Hint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "缺少命令 '$Name'。$Hint"
    }
}
