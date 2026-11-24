#!/bin/bash
# 下载 Chrome for Testing（playwright 官方 CDN 常中断，改用 Google 官方源）
# 用法: 03-chrome.sh <run_root> [version]
set -euo pipefail

ROOT="${1:-/opt/pentagi}"
VER="${2:-159.0.8154.6}"
DEST="$ROOT/chrome"
ZIP="$ROOT/_dl/chrome-linux64.zip"
BIN="$DEST/chrome-linux64/chrome"

if [ -x "$BIN" ]; then
  echo "[chrome] 已存在: $("$BIN" --version 2>/dev/null | head -1)"
  exit 0
fi

mkdir -p "$ROOT/_dl" "$DEST"

URLS=(
  "https://storage.googleapis.com/chrome-for-testing-public/${VER}/linux64/chrome-linux64.zip"
  "https://cdn.npmmirror.com/binaries/chrome-for-testing/${VER}/linux64/chrome-linux64.zip"
)

ok=0
for u in "${URLS[@]}"; do
  echo "[chrome] 尝试下载 $u"
  if curl -fL --retry 3 --retry-delay 3 --retry-all-errors -C - --max-time 2400 -o "$ZIP" "$u"; then
    ok=1
    break
  fi
  echo "[chrome] 该源失败，换下一个"
done

if [ "$ok" != "1" ]; then
  echo "[chrome] 所有源都失败"
  exit 1
fi

echo "[chrome] 解压 ($(( $(stat -c%s "$ZIP") / 1048576 )) MB)"
rm -rf "$DEST/chrome-linux64"
python3 - "$ZIP" "$DEST" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
print("  extracted")
PY

chmod +x "$BIN" 2>/dev/null || true
if [ -x "$BIN" ]; then
  echo "[chrome] 完成: $("$BIN" --version 2>/dev/null | head -1)"
else
  echo "[chrome] 解压后未找到可执行文件"
  find "$DEST" -maxdepth 3 -name chrome -type f | head -5
  exit 1
fi
