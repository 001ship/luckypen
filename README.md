<div align="center">

# lucky自动化工具

**基于 PentAGI 的中文自主渗透测试平台 · Windows 一键部署**

简体中文界面 · 内置浏览器 · 本地向量嵌入 · 免外部 embedding 供应商

`Windows 10 2004+` · `Windows 11` · `WSL2` · `Docker Engine 29`

**忘了这个仓库是干嘛的？看 [WHY.md](WHY.md)**

</div>

---

## Table of Contents

- [为什么有这个仓库](WHY.md)
- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
  - [System Context](#system-context)
  - [组件职责](#组件职责)
  - [数据流](#数据流)
- [Quick Start](#quick-start)
  - [System Requirements](#system-requirements)
  - [Using Installer (Recommended)](#using-installer-recommended)
  - [Manual Installation](#manual-installation)
  - [Access Credentials](#access-credentials)
  - [Accessing from External Networks](#accessing-from-external-networks)
- [中文界面实现](#中文界面实现)
- [渗透沙箱](#渗透沙箱)
- [内置浏览器](#内置浏览器)
- [向量嵌入](#向量嵌入)
- [镜像拉取加速](#镜像拉取加速)
- [镜像自托管](#镜像自托管)
- [运维与维护](#运维与维护)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Credits](#credits)
- [License](#license)

## Overview

lucky自动化工具 是 [PentAGI](https://github.com/vxcontrol/pentagi) 的 Windows 部署方案与中文化版本。你用自然语言描述目标，一组 AI 智能体规划工作、在隔离的 Docker 沙箱里执行 nmap / Metasploit / sqlmap 等工具，记住学到的东西，最后产出报告——界面全部是中文。

- **面向谁。** 在自有 Windows 工作站上需要一套开箱即用的自动化渗透测试环境的安全工程师、渗透测试人员与红队。仅限授权测试。
- **与官方版本的区别。** 官方镜像只提供英文界面，且依赖 `vxcontrol/scraper`（网页抓取）与外部 embedding 供应商（OpenAI 等）。本项目补齐三件事：界面中文化、自建浏览器服务、本地向量嵌入，让整套栈在不依赖境外 SaaS 的前提下运行。后端二进制、数据库迁移、API 行为与官方完全一致。
- **如何安装。** 一条命令，或把仓库链接交给 AI Agent，它读 `AGENTS.md` 自己装完 —— 见 [Quick Start](#quick-start)。全程约 20~40 分钟，需要重启一次电脑。

上游项目由 [VXControl](https://vxcontrol.com) 开发；本项目为非官方中文部署方案，与 PentAGI Development Team 无隶属关系。

## Features

- **全中文界面。** 878 条词表覆盖登录、流程、模板、知识库、设置、仪表盘、版本弹窗等全部可见区域，术语统一（智能体 / 流程 / 提示词 / 向量库）。
- **运行时注入，不动官方镜像。** 汉化在浏览器 DOM 层完成，不修改前端 bundle。官方镜像升级后重建即可跟上，不存在前后端版本错配。
- **不依赖 `vxcontrol/scraper`。** 自建浏览器服务，按后端契约实现 `/markdown` `/html` `/links` `/screenshot` 四个端点，Playwright 驱动真实 Chrome 渲染 JS 站点。
- **不依赖外部 embedding 供应商。** 本地跑 `paraphrase-multilingual-MiniLM-L12-v2`（384 维多语言），暴露 OpenAI 兼容 `/v1/embeddings`。零 API 成本，数据不出本机。
- **Windows 原生体验。** 自动启用 WSL2、安装 Docker、导入 Ubuntu 发行版，无需预装 Docker Desktop / WSL / Python / Git。
- **两阶段无人值守安装。** 阶段 1 准备并提示重启，阶段 2 在重启登录后自动接续。可反复执行，失败后重跑同一条命令即可。
- **开机自启与自愈。** 计划任务在开机/登录时拉起全栈，自动修复 WSL IP 变化导致的端口转发失效、`docker-proxy` 未绑定端口的竞态。
- **AI Agent 可执行。** 仓库根目录的 [`AGENTS.md`](AGENTS.md) 写明了前置检查、执行命令、成功判据与已知失败模式，Agent 读它就能独立完成部署。
- **完整的失败排查。** 每步写入 `install.log`，结束时产出 `install-state.json` 作为机器可读的成功判据；[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) 覆盖六大类已知问题。
- **自托管，数据自控。** 全部组件运行在本机，不向任何第三方回传。

## Architecture

### System Context

```
┌─────────────────────────────────────────────────────────────────┐
│  Windows 11 / Windows 10 2004+                                  │
│                                                                 │
│   ┌──────────────────────────────────────────────────────┐      │
│   │  WSL2 发行版 "PentAGI"（Ubuntu 24.04，无 systemd）    │      │
│   │                                                      │      │
│   │   dockerd 29.x ──┬── pentagi    :8443 ──┐            │      │
│   │                  ├── pgvector   :5432   │            │      │
│   │                  └── (agent 沙箱按需创建) │            │      │
│   │                                          │            │      │
│   │   sidecar（宿主进程）                     │            │      │
│   │   ├── embedding  :8080  fastembed        │            │      │
│   │   └── scraper    :8081  Chrome 159       │            │      │
│   └──────────────────────────────────────────┼────────────┘      │
│                                              │                   │
│   netsh portproxy  127.0.0.1:8443 ───────────┘                   │
│                                              │                   │
│   浏览器 ◀────────────────────────────────────┘                   │
└─────────────────────────────────────────────────────────────────┘
```

### 组件职责

| 组件 | 来源 | 职责 |
|---|---|---|
| `vxcontrol/pentagi` | 官方镜像 | Go 后端 + React 前端，多智能体编排、工具调用、报告生成 |
| `vxcontrol/pgvector` | 官方镜像 | PostgreSQL 16 + pgvector，持久化流程、消息、向量 |
| `lucky-pentagi`（可选） | 本仓库构建 | 官方镜像 + 中文层，用于镜像化分发 |
| embedding sidecar | 本仓库 | OpenAI 兼容 `/v1/embeddings`，384 维多语言向量 |
| scraper sidecar | 本仓库 | 四个抓取端点，Playwright + Chrome for Testing |
| `install.ps1` | 本仓库 | 两阶段安装编排、汉化注入、开机自启注册 |
| `pentagi-startup.ps1` | 本仓库 | 开机自启入口，拉起全栈并刷新端口转发 |

### 数据流

```
用户输入任务
   │
   ▼
PentAGI 主智能体 ──► LLM（DeepSeek / OpenAI / 本地）
   │                    │
   │                    └─► embedding sidecar ──► pgvector（长期记忆）
   │
   ├──► 终端工具 ──► agent 沙箱容器（debian:latest）
   └──► 浏览器工具 ──► scraper sidecar ──► 目标站点
                          └─► /screenshot 截图回传 UI
```

## Quick Start

### System Requirements

| 项 | 要求 |
|---|---|
| **Windows 11** | build 22000+，本方案的主要验证环境 |
| **Windows 10** | **build 19041（2004）及以上**。19041 是 WSL2 支持 `wsl --import` 的起点，更早版本无法导入发行版。理论可用但未充分实测 |
| CPU | 需在 BIOS 开启虚拟化（VT-x / AMD-V），否则 WSL2 无法启动 |
| 内存 | ≥ 8 GB（16 GB 更稳，agent 会并行起多个沙箱） |
| 磁盘 | ≥ 20 GB 可用。装完实际占用约 9 GB（WSL 磁盘 8.5 GB + 下载缓存 0.35 GB） |
| 网络 | 首次安装需下载约 700 MB 运行时依赖 + 1.5 GB 容器镜像 |
| 权限 | 管理员（需启用 Windows 功能、写计划任务、改端口转发） |

**不需要**预装 Docker、WSL、Python、Git。

> 安装过程会**重启电脑一次**。这是 WSL2 的硬性要求——虚拟化层只在开机时加载，启用功能后不重启，WSL 无法工作。重启后安装自动接续，无需人工干预。

### Using Installer (Recommended)

**方式一：把仓库交给 AI Agent**

```
帮我部署 https://github.com/001ship/luckypen
按 AGENTS.md 执行。安装会重启一次，重启前会提示确认。
LLM Key 先不配，装完我自己填。
```

Agent 会读取 [`AGENTS.md`](AGENTS.md) 并独立完成。适合不想自己盯终端的场景。

**方式二：一条命令**

以管理员身份打开 PowerShell：

```powershell
irm https://raw.githubusercontent.com/001ship/luckypen/main/bootstrap.ps1 | iex
```

自动完成环境预检 → 下载 → 提权 → 安装 → 提示重启。

可预置 LLM 密钥：

```powershell
$env:LUCKY_DEEPSEEK_KEY = 'sk-你的密钥'
irm https://raw.githubusercontent.com/001ship/luckypen/main/bootstrap.ps1 | iex
```

**方式三：clone 后手动运行**

```powershell
git clone https://github.com/001ship/luckypen.git
cd luckypen
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Yes
```

> **必须带 `-ExecutionPolicy Bypass`**。Windows 默认执行策略会拦截未签名脚本，表现为「无法加载，因为在此系统上禁止运行脚本」；更隐蔽的是，若内部 dot-source 被拦，`.env` 里的密钥会静默生成为空值。

安装开始前会打印醒目提示并等待确认（`-Yes` 模式下是 15 秒可中止倒计时），此时尚未做任何改动。

**安装器参数：**

| 参数 | 作用 |
|---|---|
| `-Yes` | 无人值守：不询问，阶段 1 结束后 60 秒自动重启 |
| `-NoReboot` | 只做阶段 1，不重启（自己安排时间时用） |
| `-DeepSeekKey sk-xxx` | 预填 LLM 密钥 |
| `-InstallDir D:\pentagi` | 自定义安装目录，默认 `C:\pentagi` |
| `-ListenIp 0.0.0.0` | 监听地址，默认 `127.0.0.1` |
| `-ListenPort 8443` | 监听端口 |
| `-Stage deploy` | 只跑阶段 2（重跑部署时用） |

**两阶段做了什么：**

```
阶段 1（需重启）
  启用 Microsoft-Windows-Subsystem-Linux + VirtualMachinePlatform
  安装 WSL2 内核（wsl_update_x64.msi）
  下载 Ubuntu 24.04 rootfs（340 MB）
  生成 .env（随机 COOKIE_SIGNING_SALT / 数据库密码）
  注册重启后自动继续的计划任务
  ↓ 重启
阶段 2（自动接续）
  导入 WSL 发行版 → 装 Docker → 装 Python 依赖 → 下载 Chrome
  → 拉取并启动容器 → 导出前端并注入中文层 → 注册开机自启
  → 配置端口转发 → 写 install-state.json
```

### Manual Installation

已有 Docker 环境、想跳过安装器时：

```powershell
git clone https://github.com/001ship/luckypen.git
cd luckypen

# 1. 铺配置
mkdir C:\pentagi -Force
copy config\* C:\pentagi\
copy i18n\dict.js  C:\pentagi\i18n-dict.js
copy i18n\inject.js C:\pentagi\i18n-zh.js

# 2. 手写 .env（参考 config\.env.example），至少填：
#    PENTAGI_LISTEN_IP=127.0.0.1
#    PENTAGI_LISTEN_PORT=8443
#    COOKIE_SIGNING_SALT=<随机 32 位 hex>
#    PENTAGI_POSTGRES_PASSWORD=<随机密码>
#    DEEPSEEK_API_KEY=<你的密钥>
#    PENTAGI_FE_DIR=/opt/pentagi/fe-cn

# 3. 在 WSL 里部署
wsl -d PentAGI -u root -- bash -lc "cd /opt/pentagi && docker compose up -d"
```

### Access Credentials

安装完成后访问 `https://127.0.0.1:8443`（自签证书，浏览器选「继续访问」）。

| 项 | 值 |
|---|---|
| 邮箱 | `admin@pentagi.com` |
| 密码 | `admin` |
| 说明 | 首次登录强制修改密码 |

**未配置 LLM Key 时**：能登录、能浏览界面、能建流程，但执行时会因 LLM 调用失败而中断。补配方式：

```powershell
notepad C:\pentagi\.env          # 填 DEEPSEEK_API_KEY=sk-xxx
wsl -d PentAGI -u root -- bash -lc "cd /opt/pentagi && docker compose up -d pentagi"
```

### Accessing from External Networks

默认只绑 `127.0.0.1`。要让局域网访问：

```powershell
# 1. 改监听地址
notepad C:\pentagi\.env
#    PENTAGI_LISTEN_IP=0.0.0.0
#    PUBLIC_URL=https://192.168.1.100:8443

# 2. 重建容器
wsl -d PentAGI -u root -- bash -lc "cd /opt/pentagi && docker compose up -d pentagi"

# 3. 刷新端口转发
powershell -File C:\pentagi\scripts\pentagi-startup.ps1

# 4. 放行防火墙
netsh advfirewall firewall add rule name="lucky-pentagi" dir=in action=allow protocol=TCP localport=8443
```

> **公网暴露前必须配 TLS 与反向代理**。内置自签证书仅供本地使用；直接暴露到公网等于把一套能执行任意命令的 AI 系统挂在网上。

## 中文界面实现

官方前端没有 i18n 框架，英文硬编码在 97 个打包 chunk 里，且与 Tailwind 类名、GraphQL 字段名混在一起——直接改 JS 会破坏逻辑。

因此采用 **DOM 层运行时翻译**：

```javascript
MutationObserver → 发现新增/变更节点 → 查词表 → 替换文本与属性
```

| 文件 | 作用 |
|---|---|
| `i18n/dict.js` | 878 条英中词表，含品牌名替换与版本弹窗文案 |
| `i18n/inject.js` | 注入层：文本节点 / `placeholder` / `title` / `aria-label` / `alt`，日期与相对时间正则，外链改写，`window.open` 拦截 |

**设计取舍：**

- 不修改原始 bundle，官方镜像升级不受影响
- React 每次重渲染会写回英文，观察者持续校正
- 已翻译节点打标记，避免观察器自触发
- 长文本（>300 字符）不处理，避免破坏模型输出与日志

**修改词表：**

```powershell
notepad C:\pentagi\i18n-dict.js     # 加一行 "English": "中文",
wsl -d PentAGI -u root -- cp /mnt/c/pentagi/i18n-dict.js /opt/pentagi/fe-cn/i18n-dict.js
```

刷新浏览器（Ctrl+F5）即可，无需重启容器。

**维护工具**（`i18n/tools/`）：从新版本前端提取待译文案、分类去噪、扫描覆盖率。

## 渗透沙箱

agent 执行命令跑在一个独立的 Docker 沙箱里。**这个沙箱默认是裸 `debian:latest`，里面没有任何渗透工具** —— 如果不对，agent 调 nmap 会直接 `command not found`。

### 需要的镜像

```bash
vxcontrol/kali-linux:latest    5.7 GB（压缩）/ 22.66 GB（解压后）
```

含 **173 个工具 / 25 个分类**：

| 分类 | 代表工具 |
|---|---|
| 侦察扫描 | `nmap` `masscan` `amass` `theharvester` `dnsrecon` `subfinder` `dnsx` `shuffledns` |
| Web 测试 | `sqlmap` `nikto` `whatweb` `gobuster` `dirsearch` `ffuf` `feroxbuster` `wpscan` `commix` `xsstrike` `nuclei` `httpx` `katana` |
| 漏洞利用 | `msfconsole` `msfvenom` `searchsploit` |
| 密码攻击 | `hydra` `john` `hashcat` `medusa` `patator` `crunch` |
| Windows/AD | `impacket-*`(18) `evil-winrm` `netexec` `responder` `certipy-ad` `enum4linux` `mimikatz` |
| 流量隧道 | `tshark` `tcpdump` `mitmdump` `proxychains4` `chisel` `ligolo-proxy` `iodine` |
| 逆向取证 | `radare2` `binwalk` `ROPgadget` `ropper` `steghide` `foremost` `oletools` |
| 基础环境 | `python3` `pip3` `seclists` `sqlmap` `impacket` `pwntools` `scapy` `docker-cli` |

### 必须的配置

```bash
DOCKER_DEFAULT_IMAGE_FOR_PENTEST=vxcontrol/kali-linux:latest
DOCKER_IMAGE_SELECTION_MODE=fixed
DOCKER_ALLOWED_IMAGES=vxcontrol/kali-linux:latest,debian:latest
DOCKER_NET_ADMIN=true
```

### 为什么 `DOCKER_NET_ADMIN` 必须开

Kali 的 `nmap` 不是普通二进制，它带了文件 capability：

```
/usr/lib/nmap/nmap  cap_net_bind_service,cap_net_admin,cap_net_raw=eip
```

而 PentAGI 的沙箱用 `CapDrop: ALL` 加显式白名单（`backend/pkg/docker/worker_spec.go`）：

```go
capAdd := []string{
    "CHOWN", "DAC_OVERRIDE", "FSETID", "FOWNER",
    "NET_RAW", "SETGID", "SETUID", "SETFCAP", "SETPCAP",
    "NET_BIND_SERVICE", "SYS_CHROOT", "KILL", "AUDIT_WRITE", "SYS_PTRACE",
}
if cfg.DockerNetAdmin { capAdd = append(capAdd, "NET_ADMIN") }
```

`NET_RAW` 和 `NET_BIND_SERVICE` 白名单自带，**只有 `NET_ADMIN` 需要开关**。三个 cap 必须全部落在 bounding set 里，二进制才能 exec；缺一个就报：

```
/usr/bin/nmap: 6: exec: /usr/lib/nmap/nmap: Operation not permitted
```

这个报错极具误导性——看着像权限不足，实际是 **exec 阶段就被内核拒绝**，跟容器内 `id` 是不是 root 无关。

### 拉镜像：有代理就别用加速源

实测同一台机器、同一个 5.7 GB 镜像：

| 链路 | 速度 | 耗时 |
|---|---|---|
| 国内镜像加速源（1panel / daocloud / 1ms.run） | 24 MB/分钟 | **约 4 小时** |
| 走本地 HTTP 代理直连 `registry-1.docker.io` | 4635 MB/分钟 | **约 1.2 分钟** |

差 **193 倍**。原因是对 `vxcontrol/*` 这类镜像，加速源要么返回 403（daocloud 白名单拒绝）、要么建连后零字节停滞（1panel），docker 在这些源之间反复重试，整体速度被拖垮。

`scripts/wsl/start-stack.sh` 已按此实现：**探测到宿主代理就清空 `registry-mirrors` 走代理直连，探测不到才恢复加速源**。

### 验证沙箱真的用上了

```powershell
# 看沙箱容器用的什么镜像
wsl -d PentAGI -u root -- docker ps -a --filter name=pentagi-terminal --format "{{.Names}} {{.Image}}"
```

开个 flow 让它跑 `nmap -sV <目标>`，能出结果就说明通了。若报 `Operation not permitted`，回到上面检查 `DOCKER_NET_ADMIN`。
## 内置浏览器

PentAGI 的 browser 工具向 scraper 发四个请求，本项目按同样契约自建：

```
GET /markdown?url=<target>            → text/markdown
GET /html?url=<target>                → text/html
GET /links?url=<target>               → [{"Title","Link"}, ...]
GET /screenshot?fullPage=true&url=... → image/png
```

实现要点：

- **Playwright + Chrome for Testing 159**：真实渲染 JS 站点，不是简单 HTTP 抓取
- **单线程服务**：Playwright 的 sync API 绑定创建它的线程，用 `ThreadingHTTPServer` 会报 `Cannot switch to a different thread`
- **Chrome 来源**：`cdn.playwright.dev` 下载常中断，改用 `storage.googleapis.com/chrome-for-testing-public/` 官方包，通过 `SCRAPER_CHROME` 指定可执行路径

配置（`.env`）：

```bash
SCRAPER_PUBLIC_URL=http://host.docker.internal:8081/
SCRAPER_PRIVATE_URL=http://host.docker.internal:8081/
```

## 向量嵌入

本地跑 `paraphrase-multilingual-MiniLM-L12-v2`（384 维，多语言），暴露 OpenAI 兼容接口：

```bash
curl -X POST http://127.0.0.1:8080/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"input":"渗透测试目标","model":"paraphrase-multilingual-MiniLM-L12-v2"}'
```

配置（`.env`）：

```bash
EMBEDDING_PROVIDER=openai
EMBEDDING_URL=http://host.docker.internal:8080/v1
EMBEDDING_KEY=local-embed
EMBEDDING_MODEL=sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2
```

模型经 `hf-mirror.com` 下载。更换模型需改 `.env` 的 `EMBEDDING_MODEL` 与 `scripts/wsl/start-stack.sh` 的 `EMBED_MODEL`；换模型后已有向量失效，需重建知识库。

## 镜像拉取加速

首次安装要拉约 7.3 GB 镜像（pentagi 889 MB + pgvector 614 MB + kali-linux 5.7 GB）。这一节讲怎么把这一步压到最短。

### 先判断你走的是哪条路

```powershell
# 1. dockerd 有没有配代理
wsl -d PentAGI -u root -- docker info | Select-String -Pattern "HTTP Proxy|HTTPS Proxy"

# 2. 当前生效的加速源
wsl -d PentAGI -u root -- docker info --format '{{json .RegistryConfig.Mirrors}}'
```

| 情况 | 推荐做法 | 实测速度 |
|---|---|---|
| 有代理，mirrors 为空 | **保持现状，直连** | 4635 MB/分钟 |
| 有代理，mirrors 有值 | **清空 mirrors**（见下文） | 同上 |
| 没代理 | 用加速源，接受慢 | 24 MB/分钟 |
| 没代理且加速源全废 | 离线导入（见下文） | — |

> 这两个数字是同一台机器、同一个 5.7 GB 镜像实测的，差 **193 倍**。

### 方案 A：有代理就用代理直连（最快）

Docker 的 `registry-mirrors` 和代理是互斥的——配了 mirrors 就走加速源，不会走代理。而对 `vxcontrol/*` 这类镜像，加速源普遍支持很差：

| 加速源 | 实测表现 |
|---|---|
| `docker.m.daocloud.io` | 返回 403，明确拒绝（白名单不含 vxcontrol） |
| `docker.1panel.live` | manifest 能取，实际拉层时建连后零字节停滞 |
| `hub.rat.dev` | 302 跳转异常，部分层报 `magic number mismatch` |
| `docker.1ms.run` | 类似 1panel，不稳定 |
| `dockerproxy.net` | 连接超时 |

docker 会在这些源之间反复重试，整体速度被拖到 24 MB/分钟。

**改成代理直连：**

```powershell
# 1. 确认 dockerd 已带代理（start-stack.sh 会自动探测宿主代理并注入）
wsl -d PentAGI -u root -- docker info | Select-String -Pattern "HTTP Proxy"

# 2. 清空 mirrors
wsl -d PentAGI -u root -- bash -lc "python3 -c \"
import json
p='/etc/docker/daemon.json'
d=json.load(open(p))
d['registry-mirrors']=[]
json.dump(d,open(p,'w'),indent=2)
\""

# 3. 重启 dockerd
wsl -d PentAGI -u root -- /usr/local/bin/pentagi-start.sh

# 4. 确认 mirrors 已空
wsl -d PentAGI -u root -- docker info --format '{{json .RegistryConfig.Mirrors}}'
```

`start-stack.sh` 已内置这个逻辑：探测到宿主代理就自动清空 mirrors，探测不到才恢复加速源。所以正常情况下你不需要手动做。

**代理端口不是 10090？**

```powershell
wsl -d PentAGI -u root -- bash -lc "HOST_PROXY_PORT=7890 /usr/local/bin/pentagi-start.sh"
```

### 方案 B：没代理，挑一个能用的加速源

按实测可用性排序：

```json
{
  "registry-mirrors": [
    "https://docker.1panel.live",
    "https://docker.m.daocloud.io",
    "https://hub.rat.dev"
  ]
}
```

> 注意：加速源的质量随时在变，今天能用的明天可能就废了。而且各家对 `vxcontrol/*` 的支持尤其差，因为它们通常只缓存热门镜像。

**从你的 Docker Hub 仓库拉**（我已备份，同样是公共镜像，不需要登录）：

```bash
PENTAGI_IMAGE=001ship/pentagi:latest
PGVECTOR_IMAGE=001ship/pgvector:latest
```

这样至少避开 `vxcontrol/*` 这个被多数加速源拒绝的路径。但 kali 没备份（22.66 GB 太大），仍需走原路径。

### 方案 C：完全离线导入

网络实在不行，用别的机器拉好再传过来。

```powershell
# 在有网、有代理的机器上导出
wsl -d PentAGI -u root -- docker save -o /mnt/d/kali.tar vxcontrol/kali-linux:latest

# 拷到目标机器后导入
wsl -d PentAGI -u root -- docker load -i /mnt/d/kali.tar
```

体积参考：kali 导出后约 6 GB（压缩状态），U 盘或网盘传输比慢慢拉快得多。

也可以只导出小的两个：

```powershell
wsl -d PentAGI -u root -- docker save -o /mnt/d/core.tar vxcontrol/pentagi:latest vxcontrol/pgvector:latest
# 约 1.5 GB
```

### 方案 D：分步拉，先验证链路

别一上来就拉 5.7 GB。先用小镜像测通：

```powershell
# 1. 小镜像测链路（187 MB）
wsl -d PentAGI -u root -- docker pull debian:latest

# 2. 中等镜像（614 MB）
wsl -d PentAGI -u root -- docker pull vxcontrol/pgvector:latest

# 3. 主镜像（889 MB）
wsl -d PentAGI -u root -- docker pull vxcontrol/pentagi:latest

# 4. 最后才是 kali（5.7 GB）
wsl -d PentAGI -u root -- docker pull vxcontrol/kali-linux:latest
```

每步失败就停下来先解决链路问题，避免白等几小时。

### 自己测速

不确定当前链路快不快，跑这个：

```powershell
wsl -d PentAGI -u root -- bash -lc '
A=$(du -sm /var/lib/containerd/io.containerd.content.v1.content 2>/dev/null | cut -f1)
sleep 60
B=$(du -sm /var/lib/containerd/io.containerd.content.v1.content 2>/dev/null | cut -f1)
echo "当前速度: $((B-A)) MB/分钟"
'
```

| 结果 | 判断 |
|---|---|
| > 1000 MB/分钟 | 很好，代理直连在工作 |
| 100~1000 MB/分钟 | 可接受 |
| < 50 MB/分钟 | 慢，换方案 |

按 5.7 GB 算：1000 MB/分钟约 6 分钟，50 MB/分钟要 2 小时。

### 常见误区

**"我开了代理，应该快了"** —— 不一定。如果 `registry-mirrors` 有值，docker 走加速源，代理根本不参与。必须先清空 mirrors。

**"换成另一个加速源会快"** —— 多数情况无效，因为问题是这些源对 `vxcontrol/*` 的支持，不是线路质量。

**"拉了一次失败，重试就会快"** —— docker 会断点续传已下载的层，重试确实不浪费已下载部分，但速度不会变快。

**"用 VPN 全局模式就行"** —— WSL2 默认不在 VPN 的转发范围内。要么用代理（推荐），要么在 Windows 上配 TUN 模式并确认 WSL 流量被接管。
## 镜像自托管

上游镜像随时可能消失：项目停更、镜像被下架、DMCA、账号异常。本方案提供两条退路。

### 已备份的镜像

以下镜像已复制到本项目的 Docker Hub 命名空间，可直接拉取：

| 镜像 | 压缩体积 | 说明 |
|---|---|---|
| `001ship/pentagi:latest` | 265 MB | 上游 pentagi 原版（未汉化） |
| `001ship/lucky-pentagi:latest` | 265 MB | 汉化版，中文层已内置 |
| `001ship/pgvector:latest` | 147 MB | PostgreSQL 16 + pgvector |
| `001ship/debian:latest` | 47 MB | agent 沙箱基础镜像 |
| `001ship/postgres-exporter:v0.16.0` | 11 MB | 可选指标导出 |

### 切换到自有镜像源

上游不可用时，改 `.env` 三行即可，不用动 compose：

```bash
PENTAGI_IMAGE=001ship/lucky-pentagi:latest
PGVECTOR_IMAGE=001ship/pgvector:latest
PGEXPORTER_IMAGE=001ship/postgres-exporter:v0.16.0
```

然后重建：

```powershell
wsl -d PentAGI -u root -- bash -lc "cd /opt/pentagi && docker compose up -d --force-recreate"
```

### 自己备份一份

换成你自己的 Docker Hub 账号：

```powershell
.\scripts\mirror-images.ps1 -DockerUser <你的用户名>
```

脚本会 pull → tag → push 最小可运行集合（3 个镜像，约 1.7 GB 解压后）。
加 `-IncludeOptional` 连 Langfuse / Graphiti / 监控栈一起备份（再多约 5 GB）。
加 `-ExportDir D:\backup` 额外 `docker save` 成 tar，做完全离线的副本。

镜像清单在 [`config/images.manifest`](config/images.manifest)，标了用途、是否必需、体积。

> **注意**：push 要走 `registry-1.docker.io`，拉取可以走加速源但推送没有。若直连不通，需要在 Windows 宿主上跑 HTTP 代理——`scripts/wsl/start-stack.sh` 会自动探测默认网关上的代理端口（默认 10090）并注入 `dockerd`，同时把加速源域名放进 `NO_PROXY` 以免拉取变慢。

### 关于"项目彻底消失"

镜像备份只冻结了运行状态。若上游停更，你手上这份会停在 `2.2.0-ce`。要完全自主还需要归档源码：

```powershell
git clone https://github.com/vxcontrol/pentagi.git C:\pentagi-src
```

本仓库的汉化层是运行时注入，不依赖源码版本，上游再怎么变都能叠加。
## 运维与维护

```powershell
# 全栈健康检查
curl.exe -sk -o NUL -w "%{http_code}`n" https://127.0.0.1:8443/
wsl -d PentAGI -u root -- docker ps
wsl -d PentAGI -u root -- curl -s http://127.0.0.1:8080/health   # embedding
wsl -d PentAGI -u root -- curl -s http://127.0.0.1:8081/health   # scraper

# 重启全栈（同时修复端口转发）
powershell -File C:\pentagi\scripts\pentagi-startup.ps1

# 只看容器日志
wsl -d PentAGI -u root -- docker logs pentagi --tail 100

# 改配置后重载
notepad C:\pentagi\.env
wsl -d PentAGI -u root -- bash -lc "cd /opt/pentagi && docker compose up -d pentagi"

# 卸载
schtasks /Delete /TN "PentAGI Stack Boot" /F
schtasks /Delete /TN "PentAGI Stack Startup" /F
wsl --unregister PentAGI
Remove-Item C:\pentagi -Recurse -Force
```

**日志位置：**

| 文件 | 内容 |
|---|---|
| `C:\pentagi\install.log` | 安装全过程（每步带 `[OK]` / `[WARN]` / `[FAIL]`） |
| `C:\pentagi\install-state.json` | 安装结果（机器可读） |
| `/var/log/pentagi-stack.log`（WSL） | 每次启动记录 |
| `/var/log/scraper.log`、`/var/log/embedding.log`（WSL） | sidecar 日志 |
| `/var/log/dockerd.log`（WSL） | Docker daemon 日志 |

## Configuration

配置文件在 `C:\pentagi\.env`，关键项：

| 变量 | 说明 |
|---|---|
| `PENTAGI_LISTEN_IP` | 默认 `127.0.0.1`；局域网访问改 `0.0.0.0` |
| `PENTAGI_LISTEN_PORT` | 默认 `8443` |
| `PUBLIC_URL` | 对外 URL，影响 OAuth 回调等 |
| `COOKIE_SIGNING_SALT` | 会话签名盐，安装时随机生成 |
| `PENTAGI_POSTGRES_PASSWORD` | 数据库密码，安装时随机生成 |
| `DEEPSEEK_API_KEY` | 主 LLM 密钥。也支持 `OPEN_AI_KEY` / `ANTHROPIC_API_KEY` / `GEMINI_API_KEY` / `GLM_API_KEY` / `KIMI_API_KEY` / `QWEN_API_KEY` 等 |
| `EMBEDDING_*` | 向量嵌入端点 |
| `SCRAPER_*_URL` | 抓取器地址 |
| `DUCKDUCKGO_ENABLED` | 内置搜索，无需 Key |
| `PENTAGI_FE_DIR` | 中文前端挂载源，默认 `/opt/pentagi/fe-cn` |

完整模板见 [`config/.env.example`](config/.env.example)（342 项）。

## Troubleshooting

完整手册见 [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)，覆盖：

- 安装阶段：下载中断、WSL 内核缺失、发行版导入失败
- 容器与 Docker：`chain PREROUTING` 失败、systemd 缺失、镜像拉不下来
- 访问与端口：8443 打不开、`docker-proxy` 未绑定
- 汉化：界面仍是英文、挂载被覆盖
- 内置浏览器：Chrome 启动失败、跨线程报错
- 向量嵌入：embedder 创建失败、模型下载中断

**快速自检：**

```powershell
Get-Content C:\pentagi\install-state.json
Get-Content C:\pentagi\install.log -Tail 100
```

## Credits

- **[PentAGI](https://github.com/vxcontrol/pentagi)** — 上游项目，MIT + EULA，由 [VXControl](https://vxcontrol.com) 开发
- **[fastembed](https://github.com/qdrant/fastembed)** — 轻量 ONNX 嵌入推理
- **[Playwright](https://playwright.dev)** — 浏览器自动化
- **[Chrome for Testing](https://googlechromelabs.github.io/chrome-for-testing/)** — 无头浏览器运行时

## License

本仓库代码（安装脚本、语言包、两个 sidecar 服务）采用 **MIT**，见 [LICENSE](LICENSE)。

**关于 PentAGI 本体**：版权归 PentAGI Development Team，采用 MIT 源码许可 + [EULA](https://github.com/vxcontrol/pentagi/blob/main/EULA.md) 附加条款，并集成受 AGPL-3.0 约束（含官方项目例外）的 VXControl Cloud SDK。本项目在部署时从其**官方 Docker Hub 拉取镜像**，不重新分发镜像或其前端产物；中文层以运行时注入方式实现，不构成对原软件的修改分发。

本项目为**非官方**方案，与 PentAGI Development Team 无隶属关系，未获其背书。

**使用限制**：仅可用于已获得明确授权的渗透测试与安全评估。使用者对 AI 智能体的全部行为及其后果负责。
