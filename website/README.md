# Company website (caltechnologysolutions.com)

A static, dark-mode marketing site served by nginx in its own container. No scripts, fonts or images are loaded from anywhere else, so
it is fully portable: copy this folder to any Docker host and run it.

    docker compose up -d --build          # serves on ${BIND_ADDR:-127.0.0.1}:${WEBSITE_PORT:-3300}

Publishing: add a proxy host in Nginx Proxy Manager for `caltechnologysolutions.com` (and `www`) pointing at `<host>:3300` (HTTP),
with a Let's Encrypt certificate and Force SSL. The "Client portal" buttons link to https://msp.caltechnologysolutions.com.

Editing: all copy is in `public/index.html`; all styling in `public/styles.css`. Rebuild with `docker compose up -d --build`.
The contact address (info@caltechnologysolutions.com) appears twice in index.html; change both if it differs.
