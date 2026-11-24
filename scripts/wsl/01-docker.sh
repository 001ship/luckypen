#!/bin/bash
# 安装 Docker Engine，并处理两个 WSL 专有问题：
#   1. inbox 内核 5.10.16.3 缺 nft nat 表 -> 强制 iptables-legacy
#   2. 无 systemd -> 手动 nohup dockerd
# 用法: 01-docker.sh
set -euo pipefail

MIRROR_DOCKER="${MIRROR_DOCKER:-https://mirrors.aliyun.com/docker-ce/linux/ubuntu}"
RE_LEGACY="${RE_LEGACY:-1}"

if ! command -v docker >/dev/null 2>&1; then
  echo "[docker] 添加 GPG 与 apt 源"
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.asc ]; then
    curl -fsSL --retry 3 "$MIRROR_DOCKER/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] $MIRROR_DOCKER $VERSION_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y 2>&1 | tail -3
  echo "[docker] 安装 docker-ce"
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>&1 | tail -5
else
  echo "[docker] 已安装: $(docker --version 2>/dev/null)"
fi

# ---- iptables 兜底 ----
if [ "$RE_LEGACY" = "1" ] && command -v update-alternatives >/dev/null 2>&1; then
  if iptables-legacy -t nat -L -n >/dev/null 2>&1; then
    update-alternatives --set iptables  /usr/sbin/iptables-legacy  >/dev/null 2>&1 || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1 || true
    echo "[docker] iptables 已切到 legacy"
  else
    echo "[docker] 警告: 内核不支持 legacy nat 表，保持默认后端"
  fi
fi

# ---- daemon.json ----
if [ ! -f /etc/docker/daemon.json ]; then
  echo "[docker] 写入 daemon.json（镜像加速）"
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.1panel.live",
    "https://docker.m.daocloud.io",
    "https://hub.rat.dev"
  ],
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" },
  "features": { "buildkit": true }
}
EOF
fi

# ---- 启动 dockerd（无 systemd） ----
mkdir -p /var/log
if ! pgrep -x containerd >/dev/null 2>&1; then
  nohup containerd >/var/log/containerd.log 2>&1 &
  sleep 3
fi
if ! pgrep -x dockerd >/dev/null 2>&1; then
  nohup dockerd -H unix:///var/run/docker.sock >/var/log/dockerd.log 2>&1 &
fi

for i in $(seq 1 40); do
  docker info >/dev/null 2>&1 && break
  sleep 2
done

if docker info >/dev/null 2>&1; then
  echo "[docker] 就绪: $(docker version --format '{{.Server.Version}}')"
else
  echo "[docker] 启动失败，最后 30 行日志："
  tail -30 /var/log/dockerd.log
  exit 1
fi
