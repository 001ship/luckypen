<#
.SYNOPSIS
    PentAGI 中文部署版一键安装（Windows + WSL2 + Docker）

.DESCRIPTION
    分两阶段执行，因为启用 WSL2 必须重启：
      阶段 1 (prepare)：启用 WSL2 组件、下载内核与 Ubuntu 根文件系统、生成配置
      阶段 2 (deploy) ：导入发行版、装 Docker/Python/Chrome、部署 PentAGI、应用汉化

    不带 -Stage 时自动判断当前该跑哪一阶段，可反复执行。

.PARAMETER InstallDir
    Windows 侧安装目录，默认 C:\pentagi

.PARAMETER DeepSeekKey
    DeepSeek API Key。省略时安装后手动填 .env

.PARAMETER ListenIp
    监听地址，默认 127.0.0.1（仅本机）。局域网访问改 0.0.0.0

.PARAMETER ListenPort
    监听端口，默认 8443

.EXAMPLE
    .\install.ps1 -DeepSeekKey sk-xxxx

.EXAMPLE
    # 重启后继续
    .\install.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\pentagi',
    [string]$DeepSeekKey = '',
    [string]$ListenIp = '127.0.0.1',
    [int]$ListenPort = 8443,
    [ValidateSet('auto', 'prepare', 'deploy')][string]$Stage = 'auto',
    [string]$Distro = 'PentAGI',
    [string]$DownloadMirror = '',   # 可选：镜像加速前缀
    [switch]$Yes,                   # 无人值守：不询问，直接重启
    [switch]$NoReboot               # 只准备不重启（给需要自己安排时间的场景）
)

$ErrorActionPreference = 'Continue'
# install.ps1 位于仓库根目录，$PSScriptRoot 就是仓库根
$RepoRoot = $PSScriptRoot
. (Join-Path $RepoRoot 'scripts\lib\common.ps1')

$env:PENTAGI_LOG = Join-Path $InstallDir 'install.log'
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null }

# ---------- 提权 ----------
if (-not (Test-Admin)) {
    $args = @('-InstallDir', $InstallDir, '-ListenIp', $ListenIp, '-ListenPort', $ListenPort, '-Stage', $Stage, '-Distro', $Distro)
    if ($DeepSeekKey) { $args += @('-DeepSeekKey', $DeepSeekKey) }
    if ($Yes) { $args += '-Yes' }
    if ($NoReboot) { $args += '-NoReboot' }
    Invoke-Elevated -ScriptPath $PSCommandPath -Arguments $args
    exit
}

Write-Host ''
# 把仓库里的配置与资源铺到安装目录（幂等，prepare / deploy 两阶段都会调用）
function Install-ConfigFiles {
    param([string]$Dir)
    $cfg = Join-Path $RepoRoot 'config'
    foreach ($n in 'docker-compose.yml', 'example.custom.provider.yml', 'example.ollama.provider.yml', 'example.bedrock.provider.yml') {
        $src = Join-Path $cfg $n
        if (Test-Path $src) { Copy-Item $src $Dir -Force }
        else { Warn "缺少配置文件 config\$n（compose 挂载会失败）" }
    }
    foreach ($d in 'i18n', 'services') {
        $src = Join-Path $RepoRoot $d
        if (Test-Path $src) { Copy-Item $src (Join-Path $Dir $d) -Recurse -Force }
    }
}

# 生成 .env（不存在时）；两阶段都会调用，保证 deploy 单独跑也能用
function Ensure-EnvFile {
    param([string]$Dir, [string]$Ip, [int]$Port, [string]$Key)
    $envFile = Join-Path $Dir '.env'
    if (Test-Path $envFile) { Ok '.env 已存在，保留'; return }
    $cfg = Join-Path $RepoRoot 'config'
    $tpl = Get-Content (Join-Path $cfg '.env.example') -Encoding utf8
    $salt = Get-RandomHex 16
    $pgpass = 'Pg' + (Get-RandomHex 12)
    $overrides = [ordered]@{
        'PENTAGI_LISTEN_IP'         = $Ip
        'PENTAGI_LISTEN_PORT'       = "$Port"
        'PUBLIC_URL'                = "https://localhost:$Port"
        'COOKIE_SIGNING_SALT'       = $salt
        'PENTAGI_POSTGRES_PASSWORD' = $pgpass
        'PENTAGI_FE_DIR'            = '/opt/pentagi/fe-cn'
        'EMBEDDING_PROVIDER'        = 'openai'
        'EMBEDDING_URL'             = 'http://host.docker.internal:8080/v1'
        'EMBEDDING_KEY'             = 'local-embed'
        'EMBEDDING_MODEL'           = 'sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2'
        'EMBEDDING_BATCH_SIZE'      = '100'
        'EMBEDDING_STRIP_NEW_LINES' = 'true'
        'EMBEDDING_MAX_TEXT_BYTES'  = '8192'
        'SCRAPER_PUBLIC_URL'        = 'http://host.docker.internal:8081/'
        'SCRAPER_PRIVATE_URL'       = 'http://host.docker.internal:8081/'
        'DUCKDUCKGO_ENABLED'        = 'true'
        'SPLOITUS_ENABLED'          = 'true'
        'ASSISTANT_USE_AGENTS'      = 'false'
    }
    if ($Key) { $overrides['DEEPSEEK_API_KEY'] = $Key }

    $final = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($l in $tpl) {
        if ($l -notmatch '^([A-Z][A-Z0-9_]*)=(.*)$') { $final.Add($l); continue }
        $k = $Matches[1]
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        if ($overrides.Contains($k)) { $final.Add("$k=$($overrides[$k])") } else { $final.Add($l) }
    }
    foreach ($k in $overrides.Keys) {
        if (-not $seen.ContainsKey($k)) { $final.Add("$k=$($overrides[$k])") }
    }
    Set-Content -Path $envFile -Value $final -Encoding utf8
    Ok '已生成 .env（密钥随机化）'
    if (-not $Key) { Warn '未提供 LLM Key，安装完成后需编辑 .env 填入 DEEPSEEK_API_KEY 等' }
}
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host '   PentAGI 中文部署版 · 一键安装' -ForegroundColor Cyan
Write-Host '=====================================================' -ForegroundColor Cyan
Info "安装目录: $InstallDir"
Info "日志文件: $env:PENTAGI_LOG"
Write-Host ''

# ---------- 环境检查 ----------
Step '检查系统环境'
$os = Get-CimInstance Win32_OperatingSystem
Info "系统: $($os.Caption) build $([Environment]::OSVersion.Version.Build)"
if ([Environment]::OSVersion.Version.Build -lt 22000) {
    Fail '需要 Windows 11 (build 22000+) 或 Windows 10 21H2+'
    exit 1
}
$virt = (Get-CimInstance Win32_Processor).VirtualizationFirmwareEnabled
Info "CPU 虚拟化: $virt"
if (-not $virt) {
    Warn 'BIOS 中未开启虚拟化（VT-x/AMD-V），WSL2 可能无法启动'
}
Ok '环境检查通过'

# ---------- 判定阶段 ----------
function Get-WslFeatureState {
    param([string]$Name)
    try { return (Get-WindowsOptionalFeature -Online -FeatureName $Name).State } catch { return 'Unknown' }
}

$wslState = Get-WslFeatureState 'Microsoft-Windows-Subsystem-Linux'
$vmpState = Get-WslFeatureState 'VirtualMachinePlatform'
$kernelOk = Test-Path 'C:\Windows\System32\lxss\tools\kernel'
$distroExists = (Get-WslDistros) -contains $Distro

Info "WSL 功能: $wslState / VM 平台: $vmpState / 内核: $kernelOk / 发行版: $distroExists"

if ($Stage -eq 'auto') {
    if ($wslState -ne 'Enabled' -or $vmpState -ne 'Enabled' -or -not $kernelOk) {
        $Stage = 'prepare'
    } else {
        $Stage = 'deploy'
    }
    Info "自动判定阶段: $Stage"
}

# =====================================================================
#  阶段 1：准备（需要重启）
# =====================================================================
if ($Stage -eq 'prepare') {

    Step '启用 WSL2 相关 Windows 功能'
    foreach ($feat in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
        $state = Get-WslFeatureState $feat
        if ($state -ne 'Enabled') {
            Info "启用 $feat ..."
            $out = & dism.exe /online /enable-feature /featurename:$feat /all /norestart 2>&1
            $rc = $LASTEXITCODE
            if ($rc -ne 0 -and $rc -ne 3010) {
                Fail "启用 $feat 失败 (rc=$rc)"
                $out | Select-Object -Last 5 | ForEach-Object { Info "  $_" }
                exit 1
            }
            Ok "$feat 已启用 (rc=$rc)"
        } else {
            Ok "$feat 已是启用状态"
        }
    }

    Step '安装 WSL2 内核'
    if ($kernelOk) {
        Ok '内核已存在'
    } else {
        $msi = Join-Path $InstallDir '_dl\wsl_update_x64.msi'
        $url = 'https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi'
        if (Get-FileWithRetry -Url $url -OutFile $msi) {
            Info '安装内核包...'
            $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
            if ($p.ExitCode -eq 0 -and (Test-Path 'C:\Windows\System32\lxss\tools\kernel')) {
                Ok 'WSL2 内核安装完成'
            } else {
                Fail "内核安装失败 (exit=$($p.ExitCode))"
                exit 1
            }
        } else {
            Fail '内核下载失败'
            exit 1
        }
    }

    Step '下载 Ubuntu 根文件系统'
    $tar = Join-Path $InstallDir '_dl\ubuntu-noble-wsl.tar.gz'
    if ((Test-Path $tar) -and (Get-Item $tar).Length -gt 50MB) {
        Ok "已存在（$([math]::Round((Get-Item $tar).Length/1MB)) MB）"
    } else {
        $url = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz'
        if (-not (Get-FileWithRetry -Url $url -OutFile $tar)) {
            Fail '根文件系统下载失败'
            exit 1
        }
    }

    Step '铺设配置文件'
    Install-ConfigFiles -Dir $InstallDir
    Ok '配置与资源已铺设'

    Step '生成 .env'
    Ensure-EnvFile -Dir $InstallDir -Ip $ListenIp -Port $ListenPort -Key $DeepSeekKey
    Step '注册重启后自动继续的任务'
    $taskName = 'PentAGI Install (stage 2)'
    $tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -InstallDir `"$InstallDir`" -Stage deploy -ListenIp $ListenIp -ListenPort $ListenPort -Distro $Distro"
    & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null
    & schtasks.exe /Create /TN $taskName /TR $tr /SC ONLOGON /RL HIGHEST /F 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok "已注册任务: $taskName" } else { Warn '任务注册失败，重启后请手动运行本脚本' }

    Write-Host ''
    Write-Host '=====================================================' -ForegroundColor Yellow
    Write-Host '  阶段 1 完成，需要重启电脑' -ForegroundColor Yellow
    Write-Host '=====================================================' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  重启后会自动继续（已注册登录时任务）。' -ForegroundColor Gray
    Write-Host '  若未自动继续，请以管理员身份运行：' -ForegroundColor Gray
    Write-Host "    $PSCommandPath -InstallDir `"$InstallDir`"" -ForegroundColor White
    Write-Host ''
    Write-Host "  日志: $env:PENTAGI_LOG" -ForegroundColor Gray

# 写状态文件，便于自动化/agent 判定结果
$state = [ordered]@{
    finished_at = (Get-Date).ToString('s')
    result      = $(if ($code -eq '200') { 'ok' } else { 'warn' })
    url         = "https://127.0.0.1:$ListenPort"
    user        = 'admin@pentagi.com'
    password    = 'admin'
    install_dir = $InstallDir
    log         = $env:PENTAGI_LOG
    last_probe  = $code
}
try {
    $state | ConvertTo-Json | Set-Content (Join-Path $InstallDir 'install-state.json') -Encoding utf8
    Write-Host "  状态文件: $(Join-Path $InstallDir 'install-state.json')" -ForegroundColor Gray
} catch { }
    Write-Host ''
    if ($NoReboot) {
        Info '已指定 -NoReboot，未自动重启。稍后手动重启即可自动继续。'
    } elseif ($Yes) {
        Info '无人值守模式：60 秒后自动重启'
        & shutdown.exe /r /t 60 /c 'PentAGI 安装：重启以启用 WSL2'
    } elseif (-not $SkipRebootPrompt) {
        $ans = Read-Host '现在重启？(y/N)'
        if ($ans -match '^(y|Y)') {
            Info '60 秒后重启...'
            & shutdown.exe /r /t 60 /c 'PentAGI 安装：重启以启用 WSL2'
        } else {
            Info '已跳过重启，请自行安排时间'
        }
    }
    exit 0
}

# =====================================================================
#  阶段 2：部署
# =====================================================================
Step '铺设配置文件'
Install-ConfigFiles -Dir $InstallDir
Ensure-EnvFile -Dir $InstallDir -Ip $ListenIp -Port $ListenPort -Key $DeepSeekKey
Ok '配置与资源已就绪'

Step '检查 WSL 就绪状态'
if (-not (Test-WslReady)) {
    Fail 'WSL 不可用。请确认已重启，并检查 WSL 功能是否启用'
    exit 1
}
if (-not (Test-Path 'C:\Windows\System32\lxss\tools\kernel')) {
    Fail 'WSL2 内核缺失，请重新运行安装脚本的阶段 1'
    exit 1
}
Ok 'WSL 就绪'

# 导入发行版
if (-not ((Get-WslDistros) -contains $Distro)) {
    Step "导入发行版 $Distro"
    $tar = Join-Path $InstallDir '_dl\ubuntu-noble-wsl.tar.gz'
    if (-not (Test-Path $tar)) { Fail "缺少根文件系统: $tar"; exit 1 }
    $wslRoot = Join-Path $InstallDir 'wsl'
    New-Item -ItemType Directory -Force -Path $wslRoot | Out-Null
    Info "导入中（首次约需 1-2 分钟）..."
    & wsl.exe --import $Distro $wslRoot $tar --version 2 2>&1 | ForEach-Object { Info "  $_" }
    if ($LASTEXITCODE -ne 0) { Fail "导入失败 (rc=$LASTEXITCODE)"; exit 1 }
    Ok "发行版已导入到 $wslRoot"
} else {
    Ok "发行版 $Distro 已存在"
}
& wsl.exe --set-default $Distro 2>&1 | Out-Null

$runRoot = '/opt/pentagi'
$srcDir = (('/' + $InstallDir.Substring(0,1).ToLower() + $InstallDir.Substring(2)) -replace '\\', '/')

Write-Host ''
Info "WSL 运行目录: $runRoot"
Info "Windows 源目录: $srcDir"
Write-Host ''

$steps = @(
    @{ name = '发行版初始化';   script = '00-bootstrap.sh'; args = @($runRoot, $srcDir); root = $true },
    @{ name = '安装 Docker';    script = '01-docker.sh';    args = @();                  root = $true },
    @{ name = 'Python 运行时';  script = '02-python.sh';    args = @($runRoot);          root = $true },
    @{ name = 'Chrome 浏览器';  script = '03-chrome.sh';    args = @($runRoot);          root = $true }
)

foreach ($s in $steps) {
    Step $s.name
    $path = Join-Path $RepoRoot "scripts\wsl\$($s.script)"
    $r = Invoke-WslScript -Distro $Distro -ScriptPath $path -ScriptArgs $s.args -AsRoot:($s.root)
    $r.out | Select-Object -Last 12 | ForEach-Object { Info "  $_" }
    if ($r.rc -ne 0) {
        Fail "$($s.name) 失败 (rc=$($r.rc))"
        exit 1
    }
    Ok "$($s.name) 完成"
}

Step '部署 PentAGI 与汉化'
$deploy = Join-Path $RepoRoot 'scripts\wsl\04-deploy.sh'
$r = Invoke-WslScript -Distro $Distro -ScriptPath $deploy -ScriptArgs @($runRoot, $srcDir) -AsRoot
$r.out | ForEach-Object { Info "  $_" }
if ($r.rc -ne 0) { Fail '部署失败'; exit 1 }
Ok '部署完成'

Step '安装运行时启动脚本'
$startLocal = Join-Path $RepoRoot 'scripts\wsl\start-stack.sh'
$content = Get-Content $startLocal -Raw -Encoding utf8
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($content -replace "`r`n", "`n")))
$inner = "echo '$b64' | base64 -d > /usr/local/bin/pentagi-start.sh && chmod +x /usr/local/bin/pentagi-start.sh && echo ok"
& wsl.exe -d $Distro -u root -- bash -lc $inner 2>&1 | Out-Null
$startRc = $LASTEXITCODE
if ($startRc -eq 0) {
    Ok '/usr/local/bin/pentagi-start.sh 已安装'
} else {
    Warn "启动脚本安装失败 (rc=$startRc)"
}

Step '注册开机自启'
$starter = Join-Path $RepoRoot 'scripts\pentagi-startup.ps1'
foreach ($t in @(
    @{ n = 'PentAGI Stack Boot';    sc = 'ONSTART' },
    @{ n = 'PentAGI Stack Startup'; sc = 'ONLOGON' }
)) {
    $tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$starter`" -InstallDir `"$InstallDir`" -Distro $Distro"
    & schtasks.exe /Delete /TN $t.n /F 2>&1 | Out-Null
    & schtasks.exe /Create /TN $t.n /TR $tr /SC $t.sc /RL HIGHEST /F 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok "任务: $($t.n)" } else { Warn "任务注册失败: $($t.n)" }
}

& schtasks.exe /Delete /TN 'PentAGI Install (stage 2)' /F 2>&1 | Out-Null

Step '最终验证'
$ip = Get-WslIp -Distro $Distro
if ($ip) {
    & netsh.exe interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=$ListenPort 2>&1 | Out-Null
    & netsh.exe interface portproxy add v4tov4 listenaddress=127.0.0.1 listenport=$ListenPort connectaddress=$ip connectport=$ListenPort 2>&1 | Out-Null
    Info "portproxy: 127.0.0.1:$ListenPort -> ${ip}:$ListenPort"
}

$code = '000'
for ($i = 1; $i -le 15; $i++) {
    $code = (& curl.exe -sk -o NUL -w "%{http_code}" "https://127.0.0.1:$ListenPort/" --max-time 8 2>$null)
    if ($code -eq '200') { break }
    Start-Sleep -Seconds 4
}

Write-Host ''
if ($code -eq '200') {
    Write-Host '=====================================================' -ForegroundColor Green
    Write-Host '  安装完成' -ForegroundColor Green
    Write-Host '=====================================================' -ForegroundColor Green
    Write-Host ''
    Write-Host "  访问地址: https://127.0.0.1:$ListenPort" -ForegroundColor White
    Write-Host '  默认账号: admin@pentagi.com' -ForegroundColor White
    Write-Host '  默认密码: admin   （首次登录会强制改密）' -ForegroundColor White
    Write-Host ''
    if (-not $DeepSeekKey) {
        Warn '尚未配置 LLM Key，请编辑 .env 填入后重启容器：'
        Write-Host "    notepad $InstallDir\.env" -ForegroundColor Gray
        Write-Host "    wsl -d $Distro -u root -- bash -lc 'cd /opt/pentagi && docker compose up -d pentagi'" -ForegroundColor Gray
        Write-Host ''
    }
} else {
    Warn "HTTPS 探活返回 $code，请查看日志排查"
    Write-Host "  $env:PENTAGI_LOG" -ForegroundColor Gray
    Write-Host "  wsl -d $Distro -u root -- docker logs pentagi --tail 50" -ForegroundColor Gray
}
Write-Host "  日志: $env:PENTAGI_LOG" -ForegroundColor Gray

# 写状态文件，便于自动化/agent 判定结果
$state = [ordered]@{
    finished_at = (Get-Date).ToString('s')
    result      = $(if ($code -eq '200') { 'ok' } else { 'warn' })
    url         = "https://127.0.0.1:$ListenPort"
    user        = 'admin@pentagi.com'
    password    = 'admin'
    install_dir = $InstallDir
    log         = $env:PENTAGI_LOG
    last_probe  = $code
}
try {
    $state | ConvertTo-Json | Set-Content (Join-Path $InstallDir 'install-state.json') -Encoding utf8
    Write-Host "  状态文件: $(Join-Path $InstallDir 'install-state.json')" -ForegroundColor Gray
} catch { }
Write-Host ''
