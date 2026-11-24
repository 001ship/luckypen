<div align="center">

# 为什么会有这个仓库

**如果你半年后打开这个页面，忘了它是干嘛的 —— 看这一页就够了。**

</div>

---

## 一句话

这是 [PentAGI](https://github.com/vxcontrol/pentagi)（一个开源的 AI 自动化渗透测试工具）的 **Windows 中文部署版**。

官方版本只给英文界面，安装器只支持 Linux / macOS，而且依赖两个境外服务。这个仓库把它改成：**Windows 一条命令装好、界面全中文、不依赖任何境外 SaaS**。

## 当初动手的三个原因

| 卡在哪 | 怎么解决的 |
|---|---|
| 界面全英文，官方没有中文 | 878 条词表，在浏览器里做运行时翻译，不改官方文件 |
| `vxcontrol/scraper` 镜像拉不下来（五个加速源全废） | 自己实现浏览器服务，按后端契约写四个端点 |
| 向量检索要 OpenAI 的 key，没有 | 本地跑一个多语言向量模型，暴露 OpenAI 兼容接口 |

这三个问题不解决，工具装得上但用不了。所以才有这个仓库。

## 和官方的确切关系

**后端一个字节没改。** 汉化是在浏览器里拦截 DOM 文本做替换，官方镜像本身没动过。

```
官方镜像 vxcontrol/pentagi  (889 MB，英文)
        │
        ├─ 原样运行 → 功能完全一致
        └─ 浏览器加载两个 js → 界面变中文
```

这意味着：

- 官方的 bug 修复、新功能，你都能拿到（重新拉镜像即可）
- 官方前端结构大改时，只需要更新词表，不用改代码
- 你手上的东西永远跟着上游走，不会变成死分支

## 克隆下来能得到什么

```
config/        配置模板（compose + 342 项 .env）
i18n/          878 条中文词表 + 运行时注入层
services/      自建浏览器服务 + 自建向量嵌入服务
scripts/       两阶段安装、开机自启、镜像备份、源码归档
install.ps1    一键安装主程序
AGENTS.md      给 AI Agent 的部署指令（丢给 agent 就能自动装）
```

装完之后机器上大概是这样：

```
https://127.0.0.1:8443    中文界面
账号 admin@pentagi.com    密码 admin（首登强制改密码）
占用约 9 GB
```

## 什么时候该用这个仓库

- 你的机器是 **Windows**，不想折腾 Linux
- 你需要**中文界面**
- 你**没有 OpenAI 的 key**，也不想为向量检索付钱
- 你想**一条命令或交给 AI 装完**，不想自己配 Docker

## 什么时候直接用官方更好

- 你在 **Linux 服务器**上部署 → 官方的 `installer-latest.zip` 更成熟
- 你**看得懂英文界面**、有 OpenAI key → 官方版本没这些额外层，更纯粹
- 你需要**官方最新功能立刻可用** → 官方仓库更新更快
- 你要的是**企业版功能**（Agent Profiles / MCP / 攻击链视图）→ 那些只在 PentAGI Enterprise

## 如果忘了怎么维护

| 想知道 | 看哪 |
|---|---|
| 怎么装、参数有哪些 | [README.md](README.md) |
| 装坏了怎么修 | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |
| 界面某个词翻译错了 | `i18n/dict.js`，加一行 `"English": "中文"` |
| 让 AI 帮你装 | [AGENTS.md](AGENTS.md) |
| 上游镜像没了怎么办 | README 的「镜像自托管」章节 |
| 怎么改品牌名/仓库地址 | `i18n/inject.js` 顶部的 `REPO_OLD` / `REPO_NEW` |

## 几个容易忘的点

**汉化不需要重启。** 改完 `dict.js` 推到容器里，浏览器 Ctrl+F5 就生效。

```powershell
wsl -d PentAGI -u root -- cp /mnt/c/pentagi/i18n-dict.js /opt/pentagi/fe-cn/i18n-dict.js
```

**端口打不开先重启一次。** WSL 重启后 IP 会变，端口转发必须重设：

```powershell
powershell -File C:\pentagi\scripts\pentagi-startup.ps1
```

**装完没配 key 也能登录。** 能看界面、能建流程，只是跑任务时会报 LLM 调用失败。填 `C:\pentagi\.env` 里的 `DEEPSEEK_API_KEY` 再重启容器即可。

**镜像已经备份到自己的 Docker Hub。** 万一 `vxcontrol/pentagi` 被删，改 `.env` 三行指向 `001ship/pentagi` 就能继续用。

## 一句话记住它

> 官方 PentAGI 装不上、看不懂、用不起的那部分，这个仓库补齐了。
> 它不替代官方，只是让 Windows 上能用中文跑起来。

---

## 许可提醒

本项目是**非官方**方案，与 PentAGI Development Team 无隶属关系。

PentAGI 本体采用 MIT + EULA，集成受 AGPL-3.0 约束的 VXControl Cloud SDK。本仓库**不重新分发**其镜像或前端产物，部署时从官方 Docker Hub 拉取；中文层以运行时注入实现。

仅可用于获得明确授权的渗透测试与安全评估。
