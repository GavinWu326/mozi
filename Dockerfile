FROM node:22-slim AS builder

ARG MOZI_BUILD_COMMIT=unknown
ARG MOZI_BUILD_TIME
ARG MOZI_RELEASE_CHANNEL=stable
ENV MOZI_BUILD_COMMIT=${MOZI_BUILD_COMMIT}
ENV MOZI_BUILD_TIME=${MOZI_BUILD_TIME}
ENV MOZI_RELEASE_CHANNEL=${MOZI_RELEASE_CHANNEL}

WORKDIR /app

# Optional extra root CAs. The container does not inherit the host trust store,
# so behind a TLS-intercepting proxy every HTTPS fetch here fails with
# UNABLE_TO_GET_ISSUER_CERT_LOCALLY. node:22-slim ships no ca-certificates
# package (no update-ca-certificates, no /etc/ssl/certs bundle), so point
# NODE_EXTRA_CA_CERTS at a PEM instead — Node merges it with its built-in roots.
# Drop certificates into docker-ca/; an empty directory is a no-op.
COPY docker-ca/ /usr/local/share/extra-ca/
RUN cat /usr/local/share/extra-ca/*.pem /usr/local/share/extra-ca/*.crt \
      > /usr/local/share/extra-ca/bundle.pem 2>/dev/null || true
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/extra-ca/bundle.pem

RUN corepack enable && corepack prepare pnpm@10.29.2 --activate

# Copy entire workspace before install — pnpm needs pnpm-workspace.yaml +
# ui/package.json visible to resolve the `mozi-ui` workspace package.
COPY . .

RUN pnpm install --frozen-lockfile --prod=false

# Build server (tsup -> dist/) and Web UI (vite -> ui/dist/)
RUN pnpm build && pnpm --filter mozi-ui build

# ---
FROM node:22-slim AS runtime

ARG MOZI_BUILD_COMMIT=unknown
ARG MOZI_BUILD_TIME=unknown
ARG MOZI_BUILD_VERSION=unknown
ARG MOZI_RELEASE_CHANNEL=stable
LABEL org.opencontainers.image.version=${MOZI_BUILD_VERSION} \
      org.opencontainers.image.revision=${MOZI_BUILD_COMMIT} \
      org.opencontainers.image.created=${MOZI_BUILD_TIME} \
      ai.mozi.release.channel=${MOZI_RELEASE_CHANNEL}

WORKDIR /app

# Same optional extra root CAs as the builder stage. pip talks HTTPS to PyPI via
# OpenSSL rather than Node, so it needs the system bundle (built in the apt layer
# below) rather than NODE_EXTRA_CA_CERTS. Debian apt sources are plain http, so
# apt itself needs no trust fix.
COPY docker-ca/ /usr/local/share/extra-ca/
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/extra-ca/bundle.pem
ENV PIP_CERT=/etc/ssl/certs/ca-certificates.crt

COPY requirements/document-runtime.txt ./requirements/document-runtime.txt
COPY requirements/document-runtime-constraints.txt ./requirements/document-runtime-constraints.txt

# Bundled document/media skills (docx, pdf, pptx, xlsx, slack-gif-creator)
# declare python3 in requires.bins and pip packages in their install specs.
# Install them at build time so the skills are Ready offline instead of
# surfacing "Needs setup" in the enterprise container.
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates python3 python3-pip git poppler-utils \
    libreoffice-impress libreoffice-writer libreoffice-calc libreoffice-core fonts-noto-cjk \
  && rm -rf /var/lib/apt/lists/* \
  && for cert in /usr/local/share/extra-ca/*.pem /usr/local/share/extra-ca/*.crt; do \
       [ -f "$cert" ] || continue; \
       cp "$cert" "/usr/local/share/ca-certificates/$(basename "${cert%.*}").crt"; \
     done \
  && cat /usr/local/share/extra-ca/*.pem /usr/local/share/extra-ca/*.crt \
       > /usr/local/share/extra-ca/bundle.pem 2>/dev/null || true \
  && update-ca-certificates

# Kept in its own layer, and retried: pip treats an HTTP error from the package
# host as fatal (--retries only covers connection-level errors), so a single
# transient 4xx while fetching one wheel would otherwise invalidate the apt layer
# above and redo the ~10 minute LibreOffice install on the next attempt.
RUN for attempt in 1 2 3; do \
      pip3 install --no-cache-dir --break-system-packages --retries 10 \
        --requirement requirements/document-runtime.txt \
        --constraint requirements/document-runtime-constraints.txt && break; \
      [ "$attempt" = 3 ] && exit 1; \
      echo "pip install attempt $attempt failed; retrying"; sleep 15; \
    done \
  && python3 -c 'import defusedxml, docx, imageio, numpy, openpyxl, pandas, pdf2image, pdfplumber, PIL, pptx, pypdf, reportlab, markitdown'

RUN corepack enable && corepack prepare pnpm@10.29.2 --activate

# Root manifest + lockfile only: pnpm resolves the root importer without the
# workspace file, and pulling ui/ in here would install the UI's production
# tree (~900 MB) that this stage never uses — it copies the built ui/dist from
# the builder. desktop/ is unavailable anyway (.dockerignore).
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile --prod

COPY --from=builder /app/dist ./dist
COPY --from=builder /app/skills ./skills
COPY --from=builder /app/src/templates ./src/templates
COPY --from=builder /app/ui/dist ./ui/dist

# Single source of truth for runtime data: $MOZI_HOME (mount this as a volume).
# Persisted contents: mozi.json, .env, jwt-secret, .master-key, data/mozi.db
ENV MOZI_HOME=/data
ENV NODE_ENV=production

# Container must bind 0.0.0.0 to be reachable from outside the container.
ENV MOZI_SERVER_HOST=0.0.0.0
ENV MOZI_SERVER_PORT=9210
ENV MOZI_BUILD_SURFACE=docker
ENV MOZI_PYTHON=/usr/bin/python3
ENV PYTHONNOUSERSITE=1

RUN mkdir -p /data

EXPOSE 9210

CMD ["node", "dist/index.js"]
