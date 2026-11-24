# 018-BrowseKit / browsekit-tools 增强镜像
# 目的：在官方 mcpo 镜像基础上补齐 LibreOffice 无头转换，用于老版 .doc/.xls/.rtf/.wps 解析。
# 说明：仅用于本机 browsekit-tools 容器；不改变 mcpo 的入口行为与端口。
FROM ghcr.io/open-webui/mcpo:main

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    HOME=/root

USER root

# LibreOffice 无头组件：writer 负责 doc/rtf/wps，calc 负责 xls
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libreoffice-writer-nogui \
      libreoffice-calc-nogui \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* \
 && soffice --version

# 独立虚拟环境，预装 mcp 与 markitdown 扩展，避免启动时联网拉取
RUN python3 -m venv /opt/doc-mcp-venv \
 && /opt/doc-mcp-venv/bin/python -m pip install --no-cache-dir --upgrade pip setuptools wheel \
 && /opt/doc-mcp-venv/bin/python -m pip install --no-cache-dir \
      "mcp>=1.2,<2" \
      "markitdown[docx,pdf,xlsx,pptx]"

# Markdown -> Word 渲染依赖（独立层，置于 COPY 之前，改 server.py 时仍复用 LibreOffice/venv 缓存）
RUN /opt/doc-mcp-venv/bin/pip install --no-cache-dir "python-docx>=1.1,<2" \
 && /opt/doc-mcp-venv/bin/python -c "import docx; print('python-docx', getattr(docx, '__version__', 'ok'))"

# 透明转换包装器（工具名/入参与原 markitdown-mcp 保持一致）
COPY server.py /opt/doc-mcp/server.py
RUN chmod 0644 /opt/doc-mcp/server.py \
 && /opt/doc-mcp-venv/bin/python -c "import markitdown, mcp; print('markitdown OK'); print('mcp OK')"

WORKDIR /workspace
