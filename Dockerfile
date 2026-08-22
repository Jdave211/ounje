FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    YOUTUBE_DL_BINARY=/usr/local/bin/yt-dlp

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    dumb-init \
    ffmpeg \
    python3 \
    python3-pip \
    tesseract-ocr \
  && python3 -m pip install --no-cache-dir --break-system-packages yt-dlp \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/ounje

COPY package.json ./
RUN npm install --omit=dev \
  && npx playwright install --with-deps chromium

COPY . .

RUN useradd --create-home --shell /usr/sbin/nologin ounje \
  && chown -R ounje:ounje /opt/ounje /ms-playwright

USER ounje

ENTRYPOINT ["dumb-init", "--"]
