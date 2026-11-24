# lucky-pentagi —— 汉化版 PentAGI
#
# 基于官方镜像，只替换前端产物里的静态资源并注入中文层，
# 后端二进制、数据库迁移、API 行为全部保持原样。
#
# 构建：
#   docker build -t 001ship/lucky-pentagi:latest -f Dockerfile .
#
# 中文层工作原理见仓库 i18n/inject.js：
#   词表在浏览器里拦截 DOM 文本节点做替换，不改动原始 bundle，
#   因此官方镜像升级后重建即可跟上，不存在前后端版本错配。

FROM vxcontrol/pentagi:latest

LABEL org.opencontainers.image.title="lucky-pentagi" \
      org.opencontainers.image.description="PentAGI with Simplified Chinese UI (runtime DOM injection)" \
      org.opencontainers.image.source="https://github.com/001ship/luckypen" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/vxcontrol/pentagi:latest"

# 中文层资源
COPY i18n-dict.js   /opt/pentagi/fe/i18n-dict.js
COPY i18n-inject.js /opt/pentagi/fe/i18n-zh.js

# 在 index.html 里挂上两个脚本，并把 lang 与 title 换掉。
# 幂等：重复构建不会重复插入。
RUN set -eu; \
    f=/opt/pentagi/fe/index.html; \
    if [ ! -f "$f" ]; then echo "ERROR: 官方镜像里找不到 $f；上游结构可能变了" >&2; exit 1; fi; \
    if grep -q 'i18n-zh\.js' "$f"; then \
        echo "index.html 已注入，跳过"; \
    else \
        sed -i 's#<html lang="en"#<html lang="zh-CN"#' "$f"; \
        sed -i 's#<title>[^<]*</title>#<title>lucky自动化工具</title>#' "$f"; \
        sed -i 's#</head>#<script src="/i18n-dict.js"></script></head>#' "$f"; \
        sed -i 's#</body>#<script src="/i18n-zh.js"></script></body>#' "$f"; \
        echo "index.html 注入完成"; \
    fi; \
    grep -o '<title>[^<]*</title>' "$f"; \
    grep -c 'i18n-zh\.js' "$f"

# 健康检查：容器内自带 curl/wget 不确定，用 bash 的 /dev/tcp 探端口
HEALTHCHECK --interval=15s --timeout=5s --start-period=90s --retries=6 \
    CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/8443' || exit 1
