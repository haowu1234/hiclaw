#!/bin/bash
# start-element-web.sh - Generate Element Web config and start Nginx

MATRIX_DOMAIN="${HICLAW_MATRIX_DOMAIN:-matrix-local.hiclaw.io:8080}"

# Generate Element Web config.json pointing to local Matrix Homeserver
cat > /opt/element-web/config.json << EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "http://${MATRIX_DOMAIN}"
        }
    },
    "brand": "HiClaw",
    "disable_guests": true,
    "disable_custom_urls": false
}
EOF

# Generate Nginx config for Element Web
cat > /etc/nginx/conf.d/element-web.conf << 'NGINX'
server {
    listen 8088;
    root /opt/element-web;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location ~* ^/(config.*\.json|index\.html|i18n|version)$ {
        add_header Cache-Control "no-cache";
    }
}
NGINX

# Remove default nginx site if exists
rm -f /etc/nginx/sites-enabled/default

exec nginx -g 'daemon off;'
