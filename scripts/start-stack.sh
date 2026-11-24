#!/bin/bash
# 在 WSL 内拉起 PentAGI 全栈（无 systemd 环境）。
# 处理三个 WSL 特有坑：
#   1. inbox 内核 5.10.16.3 缺 nft nat 表 -> 强制 iptables-legacy
#   2. WSL 重启后 docker-proxy 可能绑不上 127.0.0.1:8443 -> 自动重启容器
#   3. 本地 embedding / scraper 是宿主进程，需要在容器之前就绪
set -u
mkdir -p /var/log
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log() { echo "$(date '+%F %T') $*" >> /var/log/pentagi-stack.log; echo "$*"; }

# ---------- iptables legacy ----------
if command -v update-alternatives >/dev/null 2>&1; then
  update-alternatives --set iptables  /usr/sbin/iptables-legacy  >/dev/null 2>&1
  update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1
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

# ---------- 本地 embedding 服务 (OpenAI /v1/embeddings 兼容) ----------
if ! pgrep -f "/opt/embedding/server.py" >/dev/null 2>&1; then
  cd /opt/embedding || exit 1
  HF_ENDPOINT=https://hf-mirror.com \
  EMBED_MODEL=sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2 \
  EMBED_PORT=8080 \
  nohup /opt/embedding/venv/bin/python /opt/embedding/server.py >> /var/log/embedding.log 2>&1 &
  log "embedding started"
fi

# ---------- 本地 scraper 服务 (markdown/html/links/screenshot) ----------
if ! pgrep -f "/opt/scraper/server.py" >/dev/null 2>&1; then
  SCRAPER_PORT=8081 \
  SCRAPER_CHROME=/opt/chrome/chrome-linux64/chrome \
  SCRAPER_NAV_TIMEOUT=30000 \
  SCRAPER_WAIT_MS=1200 \
  nohup /opt/embedding/venv/bin/python /opt/scraper/server.py >> /var/log/scraper.log 2>&1 &
  log "scraper started"
fi

# 等两个辅助服务就绪（最多 60s），容器起来时它们必须已可用
for i in $(seq 1 30); do
  e=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8080/health 2>/dev/null)
  s=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8081/health 2>/dev/null)
  [ "$e" = "200" ] && [ "$s" = "200" ] && break
  sleep 2
done
log "sidecar health embedding=$e scraper=$s"

# ---------- compose 起来 ----------
if [ -f /opt/pentagi/docker-compose.yml ]; then
  cd /opt/pentagi || exit 1
  docker compose up -d pgvector pentagi >/dev/null 2>&1
  # 修复 WSL 重启后 docker-proxy 未绑端口的竞态
  for i in $(seq 1 12); do
    if ss -tln 2>/dev/null | grep -q '127.0.0.1:8443'; then
      echo "PORT_BOUND"; break
    fi
    docker restart pentagi >/dev/null 2>&1
    sleep 5
  done
fi

if curl -sk -o /dev/null --max-time 8 https://127.0.0.1:8443/; then
  log "STACK_HEALTHY"
  exit 0
fi
log "STACK_UNHEALTHY"
exit 1
