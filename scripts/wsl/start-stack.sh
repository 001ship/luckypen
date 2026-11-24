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
