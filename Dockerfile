# syntax=docker/dockerfile:1

# --- Stage 1: build the web UI (Vue) ---
FROM node:20-slim AS webui-build
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build/aw-webui
COPY aw-server/aw-webui/package.json aw-server/aw-webui/package-lock.json* ./
RUN npm ci
COPY aw-server/aw-webui/ ./
# vue.config.js shells out to `git rev-parse --short HEAD` for a cosmetic
# "Web UI commit hash" shown in Settings; the real submodule .git metadata
# lives outside this build context, so stub a throwaway repo to satisfy it.
RUN rm -f .git \
    && git init -q \
    && git config user.email docker@localhost \
    && git config user.name docker \
    && git commit -q --allow-empty -m docker-build
# Mirrors the Makefile's `prebuild` target: the favicon/PWA icons referenced
# by vue.config.js (iconPaths, manifestOptions) come from the `media`
# submodule, not from the webui source tree itself.
RUN mkdir -p static \
    && cp media/logo/logo.png static/logo.png \
    && cp media/logo/logo.svg static/logo.svg \
    && npm run build

# --- Stage 2: aw-server (Python) + built web UI ---
FROM python:3.11-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY aw-core/ ./aw-core/
COPY aw-client/ ./aw-client/
COPY aw-server/ ./aw-server/

# Built web UI goes into aw_server's static folder before the editable
# install, so aw-server serves it directly (see aw_server/server.py).
RUN rm -rf ./aw-server/aw_server/static/* 2>/dev/null || true
COPY --from=webui-build /build/aw-webui/dist/ ./aw-server/aw_server/static/

RUN pip install --no-cache-dir --upgrade pip setuptools \
    && pip install --no-cache-dir -e ./aw-core -e ./aw-client -e ./aw-server

# platformdirs resolves ~/.local/share, ~/.config, ~/.cache off $HOME —
# point HOME at a volume-friendly path so a single mount persists everything.
ENV HOME=/data
RUN mkdir -p /data

EXPOSE 5600

VOLUME ["/data"]

# Catches the case where the process is alive but the API has hung/crashed
# internally (e.g. deadlocked SQLite write) — `docker ps` alone can't see that.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5600/api/0/info', timeout=3)" || exit 1

CMD ["aw-server", "--host", "0.0.0.0", "--port", "5600"]
