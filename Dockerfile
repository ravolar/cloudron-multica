# Multica for Cloudron.
#
# Thin packaging layer: the Go backend (API, WebSockets, migrations) and the Next.js web app are
# copied unmodified from Multica's official images, pinned by version and digest (bump both to the
# same release together), and run under supervisor on the Cloudron base image:
#
#   backend  ghcr.io/multica-ai/multica-backend  static Go binaries + SQL migrations, port 8080
#   web      ghcr.io/multica-ai/multica-web      Next.js standalone (Alpine), 127.0.0.1:3000
#   nginx    port 8000 (public): WebSockets and API paths to the backend, the rest to the web app

FROM ghcr.io/multica-ai/multica-backend:v0.6.2@sha256:b2ef064d197561cb9d32c6b0e6f7635195891adf74f0dbd3e289bc760efcb7d9 AS backend
FROM ghcr.io/multica-ai/multica-web:v0.6.2@sha256:08c480f25f3370af018d70c0d92111add03c37a245d55c05a729c8f01076ba51 AS web

FROM cloudron/node-base:24-20260920@sha256:d984683ec59bf2379130bf41cf3c2b6bc0453f327297d7183525cb05424e7b34

COPY --from=backend /app /app/code/backend
COPY --from=web /app /app/code/web

# The web image only ships the Alpine (musl) build of sharp, which Next.js uses for image
# optimisation; this base image is glibc. Add the glibc build of the exact versions sharp asks for,
# next to it in the pnpm store.
RUN set -eux; \
    sharp_dir=$(ls -d /app/code/web/node_modules/.pnpm/sharp@*/node_modules/sharp | head -1); \
    v=$(node -p "require('${sharp_dir}/package.json').optionalDependencies['@img/sharp-linux-x64']"); \
    lv=$(node -p "require('${sharp_dir}/package.json').optionalDependencies['@img/sharp-libvips-linux-x64']"); \
    npm install --prefix /tmp/sharp --no-save --no-package-lock --no-audit --no-fund \
        "@img/sharp-linux-x64@${v}" "@img/sharp-libvips-linux-x64@${lv}"; \
    mkdir -p "${sharp_dir}/../@img"; \
    cp -a /tmp/sharp/node_modules/@img/. "${sharp_dir}/../@img/"; \
    rm -rf /tmp/sharp /root/.npm

# Build-time gates: fail here, not on a user's server.
RUN set -eux; \
    cd /app/code/backend; \
    for b in server migrate; do \
        test -x "$b"; \
        if ldd "$b" >/dev/null 2>&1; then echo "$b is dynamically linked"; exit 1; fi; \
    done; \
    ls migrations/*.up.sql >/dev/null; \
    test -f LICENSE -a -f NOTICE; \
    test -f /app/code/web/apps/web/server.js; \
    test -d /app/code/web/apps/web/.next/static; \
    next_dir=$(ls -d /app/code/web/node_modules/.pnpm/next@*/node_modules/next | head -1); \
    node -e "const s = require(require.resolve('sharp', { paths: [process.argv[1]] })); \
      s({ create: { width: 4, height: 4, channels: 3, background: '#f00' } }).webp().toBuffer() \
        .then(b => console.log('sharp ok, libvips', s.versions.vips, b.length, 'bytes'))" "${next_dir}"; \
    node -v

# Supervisor's own log and child logs default to /var/log, which is read-only on Cloudron.
RUN sed -e 's,^logfile=.*$,logfile=/run/supervisord.log,' \
        -e 's,^childlogdir=.*$,childlogdir=/run,' \
        -e 's,^\[supervisord\]$,[supervisord]\nuser=root,' \
        -i /etc/supervisor/supervisord.conf

COPY start.sh app-env.sh backend.sh web.sh nginx.conf /app/pkg/
COPY supervisor/ /etc/supervisor/conf.d/
# Set modes explicitly: the build context can arrive with 0600 files (seen with Cloudron's
# on-server build), and the processes run as `cloudron`.
RUN chmod 0755 /app/pkg /app/pkg/start.sh /app/pkg/app-env.sh /app/pkg/backend.sh /app/pkg/web.sh \
    && chmod 0644 /app/pkg/nginx.conf /etc/supervisor/conf.d/*.conf

RUN mkdir -p /run/multica/nginx \
    && echo 'set_real_ip_from 172.18.0.1;' > /run/multica/nginx-http.conf \
    && nginx -e stderr -t -c /app/pkg/nginx.conf \
    && rm -rf /run/multica

CMD [ "/app/pkg/start.sh" ]
