# syntax=docker/dockerfile:1

# --- Stage 1: build the web UI (Vue) ---
FROM node:20-slim AS webui-build
WORKDIR /build/aw-webui
COPY aw-server/aw-webui/package.json aw-server/aw-webui/package-lock.json* ./
RUN npm ci
COPY aw-server/aw-webui/ ./
RUN rm -f .git
# Real commit hash for the "Web UI commit hash" shown in Settings — the
# submodule's real .git metadata isn't in this build context, so it's passed
# in via `--build-arg WEBUI_COMMIT_HASH=$(cd aw-server/aw-webui && git
# rev-parse --short HEAD)` (see "Releasing a new version" in README).
ARG WEBUI_COMMIT_HASH=dev
ENV WEBUI_COMMIT_HASH=${WEBUI_COMMIT_HASH}
# The favicon/PWA icons referenced by vue.config.js (iconPaths,
# manifestOptions) come from branding/, a Chronly-own icon — not
# ActivityWatch's own logo, which the fork license forbids reusing.
RUN mkdir -p static \
    && cp branding/logo.png static/logo.png \
    && cp branding/logo.svg static/logo.svg \
    && npm run build

# --- Stage 2: aw-server (Python) + built web UI ---
FROM python:3.11-slim AS runtime

# Set via `--build-arg CHRONLY_VERSION=$(cat VERSION)` at release time (see
# "Releasing a new version" in README) so Settings shows Chronly's own
# release version instead of aw-server's untouched internal API version.
ARG CHRONLY_VERSION=dev

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY aw-core/ ./aw-core/
COPY aw-client/ ./aw-client/
COPY aw-server/ ./aw-server/

RUN sed -i "s/^__version__ = .*/__version__ = \"${CHRONLY_VERSION}\"/" \
    ./aw-server/aw_server/__about__.py

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
