<#
.SYNOPSIS
    把 PentAGI 依赖的全部镜像复制到自己的 Docker Hub 仓库

.DESCRIPTION
    上游镜像随时可能消失（项目停更、镜像被删、DMCA、账号问题）。
    本脚本把需要的镜像 pull 下来、重新 tag 到你的命名空间、再 push 上去。
    之后即使 vxcontrol/pentagi 被删，你也能从自己的仓库拉。

    只处理「最小可运行集合」，可选栈（Langfuse / Graphiti / 监控）默认跳过，
    加 -IncludeOptional 才一起备份。

.PARAMETER DockerUser
    Docker Hub 用户名，例如 001ship

.PARAMETER Tag
    给镜像打的版本标签，默认 latest

.PARAMETER IncludeOptional
    同时备份可选组件（Langfuse / Graphiti / 监控栈），体积会多出约 5 GB

.PARAMETER ExportDir
    同时导出 tar 到指定目录（离线备份，不依赖 Docker Hub）

.EXAMPLE
    .\mirror-images.ps1 -DockerUser 001ship

.EXAMPLE
    .\mirror-images.ps1 -DockerUser 001ship -ExportDir D:\backup
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DockerUser,
    [string]$Tag = 'latest',
    [switch]$IncludeOptional,
    [string]$ExportDir,
    [string]$Distro = 'PentAGI'
)

$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $RepoRoot 'config\images.manifest'

function Write-Step([string]$m) { Write-Host "[步骤] $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "[OK  ] $m" -ForegroundColor Green }
function Write-Warn2([string]$m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err([string]$m)  { Write-Host "[FAIL] $m" -ForegroundColor Red }

# 在 WSL 里执行 docker 命令（Windows 没有 docker CLI）
function Invoke-Docker {
    param([string[]]$DockerArgs, [int]$TimeoutSec = 0)
    $cmd = "docker " + ($DockerArgs -join ' ')
    $out = & wsl.exe -d $Distro -u root -- bash -lc $cmd 2>&1
    return @{ rc = $LASTEXITCODE; out = ($out | ForEach-Object { "$_" }) }
}

# ---------- 解析清单 ----------
if (-not (Test-Path $manifestPath)) { Write-Err "找不到清单: $manifestPath"; exit 1 }

$images = @()
foreach ($line in (Get-Content $manifestPath -Encoding utf8)) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    if ($t -notmatch '^\s*(\w+)\s*\|\s*([^\s|]+)\s*\|\s*([^|]+)\|') { continue }
    $kind = $Matches[1]
    $image = $Matches[2]
    $required = $Matches[3].Trim()

    if ($kind -eq 'optional' -and -not $IncludeOptional) { continue }
    if ($required -match '不用') { continue }
    if ($image -match '^neo4j:') { continue }   # 清单里但 compose 未引用

    $images += [pscustomobject]@{ Kind = $kind; Image = $image; Required = $required }
}

if (-not $images) { Write-Err '清单解析后没有可处理的镜像'; exit 1 }

Write-Host ''
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host "  镜像备份 -> docker.io/$DockerUser" -ForegroundColor Cyan
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "待处理 $($images.Count) 个镜像：" -ForegroundColor White
foreach ($i in $images) { Write-Host ("  {0,-64} {1}" -f $i.Image, $i.Required) }
Write-Host ''

# ---------- 登录检查 ----------
Write-Step '检查 Docker Hub 登录状态'
$r = Invoke-Docker @('info', '--format', "'{{json .RegistryConfig.Auths}}'")
if ($r.out -join ' ' -match 'docker\.io') {
    Write-Ok '已登录 docker.io'
} else {
    Write-Warn2 '未登录 docker.io'
    Write-Host ''
    Write-Host '  请先在 WSL 里登录。执行：' -ForegroundColor White
    Write-Host "    wsl -d $Distro -u root -- docker login -u $DockerUser" -ForegroundColor Gray
    Write-Host ''
    Write-Host '  密码处粘贴 Docker Hub Access Token（不是登录密码）：' -ForegroundColor White
    Write-Host '    https://hub.docker.com/settings/security -> New Access Token -> Read & Write' -ForegroundColor Gray
    Write-Host ''
    $ans = Read-Host '  登录完成后按回车继续，输入 n 退出'
    if ($ans -match '^n') { Write-Warn2 '已退出'; exit 0 }
}

# ---------- 逐个处理 ----------
$ok = 0; $skip = 0; $fail = 0
$failedList = @()

foreach ($item in $images) {
    $src = $item.Image
    $name = ($src -split '/')[-1]
    $base = $name.Split(':')[0]
    $dst = "$DockerUser/$base`:$Tag"

    Write-Host ''
    Write-Step "$src  ->  $dst"

    # 1. 本地已有就不重复拉
    $has = Invoke-Docker @('image', 'inspect', "'$src'", '--format', "'{{.Id}}'")
    if ($has.rc -ne 0) {
        Write-Host '  pull ...' -NoNewline
        $p = Invoke-Docker @('pull', "'$src'")
        if ($p.rc -ne 0) {
            Write-Err "pull 失败：$($p.out | Select-Object -Last 1)"
            $fail++; $failedList += $src; continue
        }
        Write-Host ' ok' -ForegroundColor Green
    } else {
        Write-Host '  本地已有，跳过 pull' -ForegroundColor DarkGray
    }

    # 2. tag
    $tg = Invoke-Docker @('tag', "'$src'", "'$dst'")
    if ($tg.rc -ne 0) { Write-Err 'tag 失败'; $fail++; $failedList += $src; continue }

    # 3. push
    Write-Host '  push ...' -NoNewline
    $ps = Invoke-Docker @('push', "'$dst'")
    if ($ps.rc -ne 0) {
        Write-Err "push 失败：$($ps.out | Select-Object -Last 1)"
        $fail++; $failedList += $src; continue
    }
    Write-Host ' ok' -ForegroundColor Green
    $ok++

    # 4. 可选导出
    if ($ExportDir) {
        $safe = ($src -replace '[/:]', '_')
        $tar = Join-Path $ExportDir "$safe.tar"
        if (-not (Test-Path (Split-Path $tar -Parent))) { New-Item -ItemType Directory -Force -Path (Split-Path $tar -Parent) | Out-Null }
        Write-Host "  save -> $tar ..." -NoNewline
        $sv = Invoke-Docker @('save', '-o', "'$(($tar -replace '\\','/') -replace '^C:','/mnt/c')'", "'$dst'")
        if ($sv.rc -eq 0) { Write-Host ' ok' -ForegroundColor Green } else { Write-Host ' 失败' -ForegroundColor Yellow }
    }
}

# ---------- 汇总 ----------
Write-Host ''
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host '  完成' -ForegroundColor Cyan
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host "  成功: $ok   失败: $fail   跳过: $skip"
if ($failedList.Count -gt 0) {
    Write-Host ''
    Write-Host '  失败的镜像：' -ForegroundColor Yellow
    $failedList | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '  常见原因：网络超时（重跑即可续传）、Docker Hub 限流、token 无写权限' -ForegroundColor Gray
}
Write-Host ''
Write-Host '  切换到自有镜像源：编辑 .env，把 *_IMAGE 改成自己的仓库：' -ForegroundColor White
Write-Host "    PENTAGI_IMAGE=$DockerUser/pentagi`:$Tag" -ForegroundColor Gray
Write-Host "    PGVECTOR_IMAGE=$DockerUser/pgvector`:$Tag" -ForegroundColor Gray
Write-Host "    PGEXPORTER_IMAGE=$DockerUser/postgres-exporter`:$Tag" -ForegroundColor Gray
Write-Host ''
Write-Host '  然后重建：' -ForegroundColor White
Write-Host "    wsl -d $Distro -u root -- bash -lc `"cd /opt/pentagi && docker compose up -d --force-recreate`"" -ForegroundColor Gray
Write-Host ''
