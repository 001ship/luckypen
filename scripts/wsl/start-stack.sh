#!/bin/bash
# PentAGI 全栈启动（WSL 内，无 systemd 环境）
#
# 处理三个 WSL 专有问题：
#   1. inbox 内核缺 nft nat 表      -> iptables 切 legacy
#   2. docker-proxy 偶发不绑端口    -> 检测不到就重启容器
#   3. sidecar 是宿主进程，容器依赖 -> 先起 sidecar 并等 health
set -uo pipefail

ROOT="${PENTAGI_ROOT:-/opt/pentagi}"
VENV="$ROOT/venv"
CHROME="$ROOT/chrome/chrome-linux64/chrome"
EMBED_MODEL="${EMBED_MODEL:-sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2}"
EMBED_PORT="${EMBED_PORT:-8080}"
SCRAPER_PORT="${SCRAPER_PORT:-8081}"

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mkdir -p /var/log

log() { echo "$(date '+%F %T') $*" >> /var/log/pentagi-stack.log; echo "$*"; }

# ---------- iptables legacy ----------
if command -v update-alternatives >/dev/null 2>&1 && iptables-legacy -t nat -L -n >/dev/null 2>&1; then
  update-alternatives --set iptables  /usr/sbin/iptables-legacy  >/dev/null 2>&1 || true
  update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1 || true
fi

# ---------- containerd + dockerd ----------
if ! pgrep -x containerd >/dev/null 2>&1; then
  nohup containerd >/var/log/containerd.log 2>&1 &
  sleep 3
fi
if ! pgrep -x dockerd >/dev/null 2>&1; then
  # 探测 Windows 宿主机上的 HTTP 代理。
  # WSL 里 127.0.0.1 指向 WSL 自身，访问宿主代理要用默认网关地址。
  # 拉镜像走 registry-mirrors（见 daemon.json），push 只能走 registry-1.docker.io，
  # 在直连不通的网络里必须靠这个代理。
  HOST_GW=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
  HOST_PROXY=""
  if [ -n "${HOST_GW:-}" ] && timeout 3 bash -c "echo > /dev/tcp/$HOST_GW/${HOST_PROXY_PORT:-10090}" 2>/dev/null; then
    HOST_PROXY="http://$HOST_GW:${HOST_PROXY_PORT:-10090}"
    log "detected host proxy: $HOST_PROXY"
  fi
  if [ -n "$HOST_PROXY" ]; then
    export HTTP_PROXY="$HOST_PROXY" HTTPS_PROXY="$HOST_PROXY"
    export NO_PROXY="localhost,127.0.0.1,::1"
    # 有代理时清空 registry-mirrors，让 docker 直连 registry-1.docker.io。
    # 实测差异极大：走国内加速源约 24 MB/分钟，走代理直连约 4.6 GB/分钟，
    # 同一个 5.7 GB 镜像前者要 4 小时、后者 1.2 分钟。原因是对 vxcontrol/*
    # 这类镜像，加速源要么 403 要么卡死，反而拖慢整体。
    if [ -f /etc/docker/daemon.json ]; then
      python3 - <<'PY' 2>/dev/null || true
import json
p = '/etc/docker/daemon.json'
try:
    d = json.load(open(p))
except Exception:
    raise SystemExit(0)
if d.get('registry-mirrors'):
    d['registry-mirrors'] = []
    json.dump(d, open(p, 'w'), indent=2)
    print('  registry-mirrors cleared: proxy direct is faster')
PY
    fi
  else
    # 没有代理时保留加速源，否则国内网络拉不动镜像
    if [ -f /etc/docker/daemon.json ]; then
      python3 - <<'PY' 2>/dev/null || true
import json
p = '/etc/docker/daemon.json'
MIRRORS = ["https://docker.1panel.live", "https://docker.m.daocloud.io", "https://hub.rat.dev"]
try:
    d = json.load(open(p))
except Exception:
    raise SystemExit(0)
if not d.get('registry-mirrors'):
    d['registry-mirrors'] = MIRRORS
    json.dump(d, open(p, 'w'), indent=2)
    print('  registry-mirrors restored (no proxy)')
PY
    fi
  fi
  nohup dockerd -H unix:///var/run/docker.sock >/var/log/dockerd.log 2>&1 &
fi
for i in $(seq 1 60); do
  docker info >/dev/null 2>&1 && break
  sleep 2
done
if ! docker info >/dev/null 2>&1; then
  log "DOCKER_FAILED"; tail -20 /var/log/dockerd.log; exit 1
fi
log "DOCKER_READY"

# ---------- embedding sidecar ----------
if ! pgrep -f "$ROOT/services/embedding/server.py" >/dev/null 2>&1; then
  if [ -x "$VENV/bin/python" ]; then
    HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}" \
    EMBED_MODEL="$EMBED_MODEL" \
    EMBED_PORT="$EMBED_PORT" \
    nohup "$VENV/bin/python" "$ROOT/services/embedding/server.py" >> /var/log/embedding.log 2>&1 &
    log "embedding started"
  else
    log "embedding skipped (no venv)"
  fi
fi

# ---------- scraper sidecar ----------
if ! pgrep -f "$ROOT/services/scraper/server.py" >/dev/null 2>&1; then
  if [ -x "$VENV/bin/python" ] && [ -x "$CHROME" ]; then
    SCRAPER_PORT="$SCRAPER_PORT" \
    SCRAPER_CHROME="$CHROME" \
    SCRAPER_NAV_TIMEOUT="${SCRAPER_NAV_TIMEOUT:-30000}" \
    SCRAPER_WAIT_MS="${SCRAPER_WAIT_MS:-1200}" \
    nohup "$VENV/bin/python" "$ROOT/services/scraper/server.py" >> /var/log/scraper.log 2>&1 &
    log "scraper started"
  else
    log "scraper skipped (missing venv or chrome)"
  fi
fi

# 等 sidecar 就绪
probe() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$1" 2>/dev/null)
  [ -z "$code" ] && code=000
  printf '%s' "$code"
}

e=000; s=000
for i in $(seq 1 30); do
  e=$(probe "http://127.0.0.1:$EMBED_PORT/health")
  s=$(probe "http://127.0.0.1:$SCRAPER_PORT/health")
  [ "$e" = "200" ] && [ "$s" = "200" ] && break
  sleep 2
done
log "sidecar health embedding=$e scraper=$s"

# ---------- compose ----------
if [ -f "$ROOT/docker-compose.yml" ]; then
  cd "$ROOT" || exit 1
  docker compose up -d pgvector pentagi >/dev/null 2>&1
  for i in $(seq 1 12); do
    if ss -tln 2>/dev/null | grep -q '127.0.0.1:8443'; then
      echo "PORT_BOUND"; break
    fi
    docker restart pentagi >/dev/null 2>&1
    sleep 5
  done
fi

# ---------- 探活 ----------
if curl -sk -o /dev/null --max-time 8 https://127.0.0.1:8443/; then
  log "STACK_HEALTHY"
  exit 0
fi
log "STACK_UNHEALTHY"
exit 1
