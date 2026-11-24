# AGENTS.md — 给 AI Agent 的部署指令

> 本文件面向自动化执行者（Claude Code / Cursor / DSH / Codex / Copilot 等）。
> 人类用户请看 [README.md](README.md)。

## 项目是什么

把 PentAGI（开源自主渗透测试智能体平台）部署到 **Windows 11 + WSL2 + Docker**，
并自动应用简体中文界面、自建网页抓取器、自建向量嵌入服务。

产物是一个本地 Web 应用：`https://127.0.0.1:8443`，账号 `admin@pentagi.com` / `admin`。

## 部署一个实例的完整流程

### 前置检查（必须先做）

```powershell
# 1. Windows 版本 >= 10.0.22000
[Environment]::OSVersion.Version.Build

# 2. 必须能提权（管理员）
([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 3. 磁盘可用 >= 20 GB
(Get-PSDrive C).Free / 1GB

# 4. 内存 >= 8 GB
(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB
```

任一项不满足就**停止并告知用户**，不要尝试降级方案。

### 执行部署

```powershell
git clone https://github.com/001ship/luckypen.git
cd luckypen
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Yes
```

参数说明：

| 参数 | 作用 |
|---|---|
| `-Yes` | 无人值守：不询问，阶段 1 结束后 60 秒自动重启 |
| `-NoReboot` | 只做阶段 1，不重启（用户要自己安排时间时用） |
| `-DeepSeekKey sk-xxx` | 预填 LLM 密钥 |
| `-InstallDir D:\pentagi` | 自定义安装目录 |
| `-Stage deploy` | 只跑阶段 2（重跑部署时用） |

### 阶段 1 会做什么

启用 `Microsoft-Windows-Subsystem-Linux` + `VirtualMachinePlatform`，
下载 WSL2 内核与 Ubuntu 24.04 rootfs，生成 `.env`，注册重启后自动继续的计划任务。

**然后必须重启**，这是 WSL2 的硬性要求，无法绕过。

带 `-Yes` 时脚本会自己执行 `shutdown /r /t 60`。重启后计划任务
`PentAGI Install (stage 2)` 在用户登录时自动运行，继续阶段 2。

### 关于开始前的确认提示

脚本在**动手前**会打印一段醒目提示，说明会重启一次、为什么必须重启、
重启后会发生什么、装完在哪访问，然后才继续。此时尚未做任何改动。

- 不带 `-Yes`：等用户输入 `y` 才继续，输入其它则干净退出（exit 0，零改动）
- 带 `-Yes`：打印同样提示后进入 **15 秒倒计时**，按 Ctrl+C 可中止

所以无人值守模式下也有一个可中断窗口，不会毫无预兆地开始装、毫无预兆地重启。

### 阶段 2 会做什么

导入 WSL 发行版 → 装 Docker → 装 Python 依赖 → 下载 Chrome → 拉取并启动
PentAGI 容器 → 导出前端并注入中文层 → 注册开机自启 → 配置端口转发。

耗时约 20~40 分钟，取决于网络。

## 如何判定成功

**唯一权威判据**：`C:\pentagi\install-state.json`

```json
{
  "result": "ok",
  "url": "https://127.0.0.1:8443",
  "user": "admin@pentagi.com",
  "password": "admin",
  "last_probe": "200"
}
```

`result` 为 `"ok"` 且 `last_probe` 为 `"200"` 才算成功。

辅助验证：

```powershell
# Web 可达
curl.exe -sk -o NUL -w "%{http_code}`n" https://127.0.0.1:8443/     # 期望 200

# 容器在跑
wsl -d PentAGI -u root -- docker ps                                  # 期望 pentagi + pgvector

# 汉化生效（返回 200 且体积 > 40KB）
curl.exe -sk -o NUL -w "%{http_code} %{size_download}`n" https://127.0.0.1:8443/i18n-dict.js

# 两个 sidecar 健康
wsl -d PentAGI -u root -- curl -s http://127.0.0.1:8080/health       # {"status":"ok",...}
wsl -d PentAGI -u root -- curl -s http://127.0.0.1:8081/health       # {"status":"ok","browser":true}
```

## 中断后如何续跑

安装脚本是幂等的，**任意阶段失败后直接重跑同一条命令即可**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

不带 `-Stage` 时脚本自动判断当前该跑 prepare 还是 deploy。

## 禁止事项（会导致安装失败的做法）

| 不要做 | 原因 |
|---|---|
| 直接 `.\install.ps1` 不带 `-ExecutionPolicy Bypass` | 执行策略会拦截内部 dot-source，`.env` 里的密钥会静默生成为空值 |
| 跳过重启直接跑阶段 2 | WSL2 虚拟化层未加载，`wsl --status` 会失败 |
| 用 `wsl --unregister` 清理 | 会丢失所有已部署数据 |
| 在 WSL 里用 `systemctl` | 本项目不使用 systemd，服务由 `nohup` 托管 |
| 手改 `C:\pentagi\docker-compose.yml` 删掉 `fe-cn` 挂载 | 汉化会失效 |
| 把 `.env` 提交到 git | 含密钥 |

## 已知失败模式与处置

### `wsl --status` 报未找到 WSL 2 内核

```powershell
curl.exe -L -o "$env:TEMP\wsl.msi" https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi
Start-Process msiexec.exe -ArgumentList "/i `"$env:TEMP\wsl.msi`" /qn" -Verb RunAs -Wait
```

### dockerd 报 `chain PREROUTING` / `failed to add jump rules`

WSL 内核缺 nft nat 表：

```powershell
wsl -d PentAGI -u root -- update-alternatives --set iptables /usr/sbin/iptables-legacy
wsl -d PentAGI -u root -- update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
wsl -d PentAGI -u root -- /usr/local/bin/pentagi-start.sh
```

### 镜像拉取超时

登录国内加速源，或改用可用的镜像源：

```powershell
wsl -d PentAGI -u root -- docker info --format '{{json .RegistryConfig.Mirrors}}'
```

详见 `docs/TROUBLESHOOTING.md`。

### 装完 8443 打不开

WSL 重启后 IP 变了，端口转发失效：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\pentagi-startup.ps1
```

## 部署后的运维入口

```powershell
# 重启全栈（同时修复端口转发）
.\scripts\pentagi-startup.ps1

# 只重启容器
wsl -d PentAGI -u root -- bash -lc "cd /opt/pentagi && docker compose restart pentagi"

# 改配置
notepad C:\pentagi\.env
wsl -d PentAGI -u root -- bash -lc "cd /opt/pentagi && docker compose up -d pentagi"

# 卸载
schtasks /Delete /TN "PentAGI Stack Boot" /F
schtasks /Delete /TN "PentAGI Stack Startup" /F
wsl --unregister PentAGI
Remove-Item C:\pentagi -Recurse -Force
```

## 给 agent 的额外提示

1. **不要在部署完成前修改任何文件**，脚本自己会铺设配置。
2. **不要并行跑两个 install.ps1**，会争抢计划任务和 WSL 导入。
3. 每次执行都有完整日志落到 `C:\pentagi\install.log`，失败时读最后 100 行比猜更有效。
4. 如果需要非交互地验证 UI，可用：

```powershell
& "C:\Program Files\Google\Chrome\Application\chrome.exe" --headless=new `
  --ignore-certificate-errors --no-sandbox --hide-scrollbars `
  --window-size=1440,900 --virtual-time-budget=9000 `
  --screenshot="$env:TEMP\shot.png" https://127.0.0.1:8443/
```
