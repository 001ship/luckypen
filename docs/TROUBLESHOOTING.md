# 故障排查

按现象索引。所有日志默认在 `C:\pentagi\install.log`，WSL 内日志在 `/var/log/`。

---

## 安装阶段

### 脚本报「需要管理员权限」后没反应

UAC 被拒绝。右键 PowerShell → **以管理员身份运行**，再执行 `install.ps1`。

### 阶段 1 卡在下载

WSL 内核 16 MB、Ubuntu rootfs 340 MB。国内直连 `cloud-images.ubuntu.com` 可能很慢：

```powershell
# 先手动下载到指定位置，脚本会自动跳过
curl.exe -L -C - -o C:\pentagi\_dl\ubuntu-noble-wsl.tar.gz `
  https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz
```

脚本用 `curl -C -` 断点续传，直接重跑即可接着下。

### `wsl --status` 提示「未找到 WSL 2 内核」

只启用了功能开关，没装内核组件。手动补：

```powershell
curl.exe -L -o "$env:TEMP\wsl.msi" https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi
Start-Process msiexec.exe -ArgumentList "/i `"$env:TEMP\wsl.msi`" /qn" -Verb RunAs -Wait
```

装完 `Test-Path C:\Windows\System32\lxss\tools\kernel` 应为 `True`。

### 导入发行版失败

```powershell
# 看是否已存在同名发行版
wsl -l -v
# 需要清理时
wsl --unregister PentAGI
```

磁盘空间不足也会失败（导入约需 3 GB）。

---

## 容器与 Docker

### dockerd 起不来：`failed to add jump rules to nat-PREROUTING`

WSL 的 inbox 内核（5.10.16.3）缺 nft nat 表。确认 iptables 后端：

```bash
wsl -d PentAGI -u root -- iptables --version     # 应显示 (legacy)
wsl -d PentAGI -u root -- update-alternatives --set iptables /usr/sbin/iptables-legacy
wsl -d PentAGI -u root -- update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
wsl -d PentAGI -u root -- pkill -x dockerd
wsl -d PentAGI -u root -- /usr/local/bin/pentagi-start.sh
```

### `System has not been booted with systemd as init system`

正常现象。本项目**不使用 systemd**，dockerd 由 `pentagi-start.sh` 用 `nohup` 托管。看到这条错误说明有脚本试图用 `systemctl`，忽略即可。

### 镜像拉不下来

`registry-1.docker.io` 在部分网络下不可达。检查当前加速源：

```bash
wsl -d PentAGI -u root -- docker info --format '{{json .RegistryConfig.Mirrors}}'
```

不同镜像源对仓库的白名单不同，实测：

| 源 | 可用性 |
|---|---|
| `docker.1panel.live` | 较全，但偶尔连接挂起 |
| `docker.m.daocloud.io` | 对 `vxcontrol/*` 返回 403（白名单拒绝） |
| `hub.rat.dev` | 部分层数据损坏（`magic number mismatch`） |
| `dockerproxy.net` | 经常超时 |

换源：

```bash
wsl -d PentAGI -u root -- bash -lc 'cat > /etc/docker/daemon.json <<EOF
{ "registry-mirrors": ["https://docker.1panel.live"] }
EOF
pkill -x dockerd; sleep 3; nohup dockerd >/var/log/dockerd.log 2>&1 &'
```

若加速源全废且有可用代理，给 dockerd 加代理：

```bash
wsl -d PentAGI -u root -- bash -lc 'mkdir -p /etc/systemd/system/docker.service.d'
# 或直接以环境变量启动：
wsl -d PentAGI -u root -- bash -lc 'pkill -x dockerd; sleep 2; \
  HTTPS_PROXY=http://<宿主IP>:<端口> nohup dockerd >/var/log/dockerd.log 2>&1 &'
```

WSL 里访问 Windows 宿主的代理，用 `ip route show default` 的网关地址，不是 `127.0.0.1`。

---

## 访问与端口

### 浏览器打不开 `https://127.0.0.1:8443`

分三层查：

```powershell
# 1. 容器在跑吗
wsl -d PentAGI -u root -- docker ps

# 2. WSL 内部通吗
wsl -d PentAGI -u root -- curl -sk -o /dev/null -w "%{http_code}\n" https://127.0.0.1:8443/

# 3. Windows 侧转发通吗
curl.exe -sk -o NUL -w "%{http_code}`n" https://127.0.0.1:8443/
```

第 2 步通、第 3 步不通 → 端口转发问题：

```powershell
.\scripts\pentagi-startup.ps1
```

它会把 `netsh portproxy` 重设到当前 WSL IP（**WSL 每次重启 IP 都会变**，这是必须的）。

查看当前转发：

```powershell
netsh interface portproxy show v4tov4
```

### 容器在跑但端口没监听

WSL 重启后偶发 `docker-proxy` 不绑端口。重启容器：

```powershell
wsl -d PentAGI -u root -- docker restart pentagi
```

`pentagi-start.sh` 已内置该自愈逻辑（检测不到 8443 监听就自动重启，最多 12 次）。

---

## 汉化

### 界面还是英文

```powershell
# 1. 前端资源是否被挂载
wsl -d PentAGI -u root -- docker exec pentagi ls /opt/pentagi/fe/i18n-*.js

# 2. index.html 是否注入
wsl -d PentAGI -u root -- docker exec pentagi grep -c i18n-zh /opt/pentagi/fe/index.html
```

若为空或 0，重新部署汉化：

```powershell
wsl -d PentAGI -u root -- bash -lc 'rm -rf /opt/pentagi/fe-cn && mkdir -p /opt/pentagi/fe-cn'
wsl -d PentAGI -u root -- bash -lc 'docker cp pentagi:/opt/pentagi/fe/. /opt/pentagi/fe-cn/'
# 再跑一次 install.ps1（阶段 2 会重新注入）
.\install.ps1
```

常见的第三种原因：**升级 compose 时把 `fe-cn` 挂载覆盖掉了**。检查：

```powershell
Select-String -Path C:\pentagi\docker-compose.yml -Pattern 'fe-cn'
```

### 部分文案仍是英文

进开发者工具确认该文本是否在词表里。补词：

```powershell
notepad C:\pentagi\fe\i18n-dict.js
# 加一行  "English text": "中文",
wsl -d PentAGI -u root -- cp /mnt/c/pentagi/fe/i18n-dict.js /opt/pentagi/fe-cn/i18n-dict.js
```

刷新浏览器（Ctrl+F5）。词表结构可从 `i18n/tools/extract.js` 重新提取校验。

### 改完后浏览器还是旧版

`index.html` 和 `i18n-*.js` 没有强缓存头，但浏览器可能缓存。用 Ctrl+Shift+R 硬刷新，或开隐身窗口。

---

## 内置浏览器（scraper）

### `curl http://127.0.0.1:8081/health` 无响应

```powershell
wsl -d PentAGI -u root -- tail -50 /var/log/scraper.log
wsl -d PentAGI -u root -- ps aux | grep '[s]craper/server.py'
```

重启：

```powershell
wsl -d PentAGI -u root -- bash -lc 'fuser -k 8081/tcp; sleep 2; \
  PENTAGI_ROOT=/opt/pentagi /usr/local/bin/pentagi-start.sh'
```

### 报 `Cannot switch to a different thread`

Playwright 的 sync API 绑定创建它的线程。服务必须是**单线程** `HTTPServer`，不能是 `ThreadingHTTPServer`。检查 `services/scraper/server.py` 的 import。

### 报 `Executable doesn't exist` 或 Chrome 启动失败

```bash
wsl -d PentAGI -u root -- /opt/pentagi/chrome/chrome-linux64/chrome --version
```

缺系统库时：

```bash
wsl -d PentAGI -u root -- /opt/pentagi/venv/bin/python -m playwright install-deps chromium
```

Chrome 没下下来，单独跑：

```powershell
wsl -d PentAGI -u root -- bash -lc 'bash /tmp/03-chrome.sh /opt/pentagi'
```

### agent 说浏览器工具报错

看 PentAGI 日志里的 scraper 请求：

```powershell
wsl -d PentAGI -u root -- tail -30 /var/log/scraper-access.log
wsl -d PentAGI -u root -- docker logs pentagi --tail 50 | Select-String scraper
```

确认容器能访问宿主端口：

```powershell
wsl -d PentAGI -u root -- docker exec pentagi wget -qO- http://host.docker.internal:8081/health
```

不通 → 检查 compose 里的 `extra_hosts`：

```powershell
Select-String -Path C:\pentagi\docker-compose.yml -Pattern 'host.docker.internal'
```

---

## 向量嵌入（embedding）

### 启动日志报 `failed to create embedder`

`.env` 里的 `EMBEDDING_*` 没生效：

```powershell
wsl -d PentAGI -u root -- docker exec pentagi env | Select-String EMBEDDING
```

### 模型下载失败

模型走 `hf-mirror.com`。手动拉：

```bash
wsl -d PentAGI -u root -- bash -lc 'HF_ENDPOINT=https://hf-mirror.com \
  /opt/pentagi/venv/bin/python -c "from fastembed import TextEmbedding; TextEmbedding(model_name=\"sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2\", cache_dir=\"/opt/pentagi/models\")"'
```

### 想换成别的模型

1. 确认在 `fastembed` 支持列表内
2. 改 `.env` 的 `EMBEDDING_MODEL`
3. 改 `scripts/wsl/start-stack.sh` 的 `EMBED_MODEL`
4. 重启：`.\scripts\pentagi-startup.ps1`

> 换 embedding 模型会导致已有向量失效，需重建知识库。

---

## 完全重装

```powershell
# 1. 停任务
schtasks /Delete /TN "PentAGI Stack Boot" /F
schtasks /Delete /TN "PentAGI Stack Startup" /F
schtasks /Delete /TN "PentAGI Install (stage 2)" /F

# 2. 删端口转发
netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=8443

# 3. 注销发行版（数据全丢）
wsl --unregister PentAGI

# 4. 删目录
Remove-Item C:\pentagi -Recurse -Force

# 5. 重新安装
.\install.ps1 -DeepSeekKey sk-xxx
```

想保留数据只重装容器：跳过第 3、4 步，直接 `wsl -d PentAGI -u root -- bash -lc 'cd /opt/pentagi && docker compose down && docker compose up -d'`。

---

## 收集诊断信息

提 issue 前请附上：

```powershell
# 系统
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, BuildNumber
wsl --status
wsl -l -v

# 容器
wsl -d PentAGI -u root -- docker ps -a
wsl -d PentAGI -u root -- docker logs pentagi --tail 80

# sidecar
wsl -d PentAGI -u root -- tail -30 /var/log/scraper.log
wsl -d PentAGI -u root -- tail -30 /var/log/embedding.log

# 安装日志
Get-Content C:\pentagi\install.log -Tail 100
```

> 提交前请移除日志里的 API Key、Cookie 签名盐、数据库密码。
