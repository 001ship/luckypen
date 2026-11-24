<#
.SYNOPSIS
    PentAGI 开机启动：拉起 WSL 里的全栈，并把端口转发指到当前 WSL IP

.DESCRIPTION
    由计划任务调用（ONSTART / ONLOGON），也可手动执行用于恢复。
    WSL 每次重启 IP 都会变，所以每次都要重设 netsh portproxy。
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\pentagi',
    [string]$Distro = 'PentAGI',
    [int]$ListenPort = 8443
)

$ErrorActionPreference = 'Continue'
$log = Join-Path $InstallDir 'install.log'
function Write-Log([string]$m) {
    $line = "[{0}] [boot] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    try { Add-Content -LiteralPath $log -Value $line -Encoding utf8 } catch { }
    Write-Host $line
}

Write-Log '--- pentagi startup: begin ---'
$env:WSL_UTF8 = '1'

# 1) 拉起 WSL 内的栈
$out = & wsl.exe -d $Distro -u root -- /usr/local/bin/pentagi-start.sh 2>&1
$out | ForEach-Object { Write-Log "  wsl: $_" }
Write-Log ("pentagi-start.sh rc=" + $LASTEXITCODE)

# 2) 解析当前 WSL IP
$ipRaw = & wsl.exe -d $Distro -u root -- hostname -I 2>&1
$wslIp = (($ipRaw -join ' ').Trim().Split(' ') | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1)
Write-Log "wsl ip = $wslIp"

if (-not $wslIp) {
    Write-Log 'RESULT=FAIL 无法获取 WSL IP'
    exit 1
}

# 3) 重设端口转发
Start-Service iphlpsvc -ErrorAction SilentlyContinue | Out-Null
& netsh.exe interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=$ListenPort 2>&1 | Out-Null
& netsh.exe interface portproxy add v4tov4 listenaddress=127.0.0.1 listenport=$ListenPort connectaddress=$wslIp connectport=$ListenPort 2>&1 | Out-Null
Write-Log ("portproxy: 127.0.0.1:$ListenPort -> ${wslIp}:$ListenPort (rc=$LASTEXITCODE)")

# 4) 端到端探活
$ok = $false
for ($i = 1; $i -le 12; $i++) {
    $code = & curl.exe -sk -o NUL -w "%{http_code}" "https://127.0.0.1:$ListenPort/" --max-time 8 2>$null
    Write-Log "probe $i -> $code"
    if ($code -eq '200') { $ok = $true; break }
    Start-Sleep -Seconds 5
}

if ($ok) { Write-Log "RESULT=OK https://127.0.0.1:$ListenPort" }
else { Write-Log 'RESULT=FAIL web 不可达' }

Write-Log '--- pentagi startup: end ---'
