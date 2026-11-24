#!/bin/bash
# Python 运行时：venv + fastembed(embedding) + playwright(scraper) + 系统库
# 用法: 02-python.sh <run_root>
set -euo pipefail

ROOT="${1:-/opt/pentagi}"
VENV="$ROOT/venv"
PIP_INDEX="${PIP_INDEX:-https://pypi.org/simple}"

mkdir -p "$ROOT"

if [ ! -x "$VENV/bin/python" ]; then
  echo "[python] 创建 venv -> $VENV"
  python3 -m venv "$VENV"
fi

echo "[python] 升级 pip"
"$VENV/bin/pip" install --upgrade pip -q -i "$PIP_INDEX" 2>&1 | tail -2

need_install=0
"$VENV/bin/python" -c "import fastembed" 2>/dev/null || need_install=1
"$VENV/bin/python" -c "import playwright" 2>/dev/null || need_install=1
if [ "$need_install" = "1" ]; then
  echo "[python] 安装 fastembed / playwright / html2text"
  "$VENV/bin/pip" install -q -i "$PIP_INDEX" fastembed playwright html2text 2>&1 | tail -5
fi

echo "[python] 校验"
"$VENV/bin/python" -c "import fastembed, playwright, html2text; print('  fastembed', fastembed.__version__)"

# Playwright 的浏览器系统依赖（不下载它自带的 chromium，用 Chrome for Testing）
if [ ! -f "$ROOT/.deps-installed" ]; then
  echo "[python] 安装浏览器系统依赖"
  "$VENV/bin/python" -m playwright install-deps chromium 2>&1 | tail -4 || \
    echo "[python] 警告: install-deps 部分失败，若 Chrome 起不来请手动装 libnss3 等"
  touch "$ROOT/.deps-installed"
fi

echo "[python] 完成"
