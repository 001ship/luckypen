#!/bin/bash
# 部署 PentAGI + 中文注入层
# 用法: 04-deploy.sh <run_root> <src_dir>
set -euo pipefail

ROOT="${1:-/opt/pentagi}"
SRC="${2:-/mnt/c/pentagi}"
FE="$ROOT/fe-cn"

mkdir -p "$ROOT"

# ---------- 1. 配置 ----------
echo "[deploy] 铺配置 -> $ROOT"
for f in docker-compose.yml .env example.custom.provider.yml example.ollama.provider.yml example.bedrock.provider.yml; do
  if [ ! -f "$SRC/$f" ]; then echo "[deploy] 缺少 $SRC/$f"; exit 1; fi
  tr -d '\r' < "$SRC/$f" > "$ROOT/$f"
done

mkdir -p "$ROOT/services/scraper" "$ROOT/services/embedding"
cp -f "$SRC/services/scraper/server.py"   "$ROOT/services/scraper/server.py"
cp -f "$SRC/services/embedding/server.py" "$ROOT/services/embedding/server.py"

cd "$ROOT"
docker compose config >/dev/null 2>&1 || { echo "[deploy] compose 校验失败"; docker compose config 2>&1 | tail -5; exit 1; }

# ---------- 2. 先起一次，拿到官方前端产物 ----------
echo "[deploy] 启动基础容器"
docker compose up -d pgvector pentagi 2>&1 | tail -6

echo "[deploy] 等待 pentagi 就绪"
for i in $(seq 1 40); do
  if docker ps --format '{{.Names}}' | grep -q '^pentagi$'; then
    st=$(docker inspect -f '{{.State.Status}}' pentagi 2>/dev/null || echo unknown)
    [ "$st" = "running" ] && break
  fi
  sleep 3
done
docker ps --format '  {{.Names}} | {{.Status}}'

# ---------- 3. 汉化 ----------
if [ -f "$SRC/i18n/dict.js" ] && [ -f "$SRC/i18n/inject.js" ]; then
  echo "[deploy] 应用中文注入层"
  rm -rf "$FE"
  mkdir -p "$FE"
  docker cp pentagi:/opt/pentagi/fe/. "$FE/" 2>/dev/null || { echo "[deploy] 导出前端失败"; exit 1; }

  cp -f "$SRC/i18n/dict.js"  "$FE/i18n-dict.js"
  cp -f "$SRC/i18n/inject.js" "$FE/i18n-zh.js"

  python3 - "$FE/index.html" <<'PY'
import sys, re, io
p = sys.argv[1]
h = io.open(p, encoding='utf-8').read()
if 'i18n-zh.js' in h:
    print('  index.html 已注入，跳过')
else:
    h = h.replace('<html lang="en"', '<html lang="zh-CN"')
    h = re.sub(r'<title>[^<]*</title>', '<title>lucky自动化工具</title>', h, count=1)
    h = h.replace('</head>', '<script src="/i18n-dict.js"></script></head>')
    h = h.replace('</body>', '<script src="/i18n-zh.js"></script></body>')
    io.open(p, 'w', encoding='utf-8').write(h)
    print('  index.html 已注入')
PY

  # 挂载生效需要重建
  echo "[deploy] 重建容器以启用前端挂载"
  docker compose up -d --force-recreate pentagi 2>&1 | tail -4
else
  echo "[deploy] 未找到 i18n 资源，跳过汉化"
fi

# ---------- 4. 探活 ----------
echo "[deploy] 探活"
ok=0
for i in $(seq 1 30); do
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 6 https://127.0.0.1:8443/ 2>/dev/null || echo 000)
  if [ "$code" = "200" ]; then ok=1; echo "  HTTPS 就绪 (200)"; break; fi
  sleep 3
done

[ "$ok" = "1" ] || { echo "[deploy] HTTPS 未就绪，最后 30 行日志："; docker logs pentagi --tail 30 2>&1; exit 1; }

echo "[deploy] 完成"
