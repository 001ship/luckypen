#!/bin/bash
# 发行版初始化：基础包 + apt 源加速
# 用法: 00-bootstrap.sh <run_root> <src_dir>
set -euo pipefail

MIRROR_UBUNTU="${MIRROR_UBUNTU:-https://mirrors.aliyun.com/ubuntu}"
export DEBIAN_FRONTEND=noninteractive

echo "[bootstrap] 配置 apt 源 -> $MIRROR_UBUNTU"
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  sed -i "s|http://archive.ubuntu.com/ubuntu|${MIRROR_UBUNTU}|g; s|http://security.ubuntu.com/ubuntu|${MIRROR_UBUNTU}|g" \
    /etc/apt/sources.list.d/ubuntu.sources
fi
if [ -f /etc/apt/sources.list ]; then
  sed -i "s|http://archive.ubuntu.com/ubuntu|${MIRROR_UBUNTU}|g; s|http://security.ubuntu.com/ubuntu|${MIRROR_UBUNTU}|g" \
    /etc/apt/sources.list || true
fi

# 清掉可能残留的坏代理配置
rm -f /etc/apt/apt.conf.d/99proxy

echo "[bootstrap] apt-get update"
apt-get update -y 2>&1 | tail -4

echo "[bootstrap] 安装基础工具"
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg jq iproute2 iptables tzdata \
  python3 python3-venv python3-pip psmisc unzip 2>&1 | tail -4

echo "[bootstrap] 完成"
