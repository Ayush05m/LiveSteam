#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# USER-CONFIGURABLE VARIABLES
# ------------------------------------------------------------
REPO_URL="https://github.com/Ayush05m/LiveSteam"   # <<< CHANGE THIS
REPO_BRANCH="main"                                        # or "master"
SERVER_DOMAIN_OR_IP="$(curl -s ifconfig.me)"              # auto-detect public IP (or set manually)
STREAM_KEY="mystream"                                     # default static key (you can make it dynamic later)
NODE_PORT=3000
APP_DIR="/opt/streaming-app"
HLS_DIR="/var/www/html/hls"
NGINX_CONF="/etc/nginx/nginx.conf"
# ------------------------------------------------------------

echo "=== Live-Streaming VM Setup ==="
echo "Repo      : $REPO_URL"
echo "Branch    : $REPO_BRANCH"
echo "Public IP : $SERVER_DOMAIN_OR_IP"
echo "Stream key: $STREAM_KEY"
echo "===================================="

# 1. System update + basic tools
apt-get update -y
apt-get upgrade -y
apt-get install -y \
    build-essential libpcre3 libpcre3-dev libssl-dev zlib1g-dev \
    git wget curl unzip ca-certificates \
    ffmpeg ufw

# 2. Install Node.js 20 (LTS) via NodeSource
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# 3. Install NGINX with RTMP module (compile from source)
NGINX_VERSION="1.26.2"
cd /tmp
wget -q https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz
tar xzf nginx-${NGINX_VERSION}.tar.gz
# git clone https://github.com/arut/nginx-rtmp-module.git
cd nginx-${NGINX_VERSION}
./configure \
    --prefix=/etc/nginx \
    --sbin-path=/usr/sbin/nginx \
    --conf-path=/etc/nginx/nginx.conf \
    --error-log-path=/var/log/nginx/error.log \
    --pid-path=/var/run/nginx.pid \
    --lock-path=/var/run/nginx.lock \
    --http-log-path=/var/log/nginx/access.log \
    --with-http_ssl_module \
    --add-module=../nginx-rtmp-module
make -j$(nproc)
make install

# systemd unit for NGINX
cat >/etc/systemd/system/nginx.service <<'EOF'
[Unit]
Description=nginx - high performance web server
After=network.target

[Service]
Type=forking
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable nginx

# 4. Create HLS directory
mkdir -p "$HLS_DIR"
chown www-data:www-data "$HLS_DIR"

# 5. Clone your repo
mkdir -p "$(dirname "$APP_DIR")"
git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$APP_DIR"
cd "$APP_DIR"

# If the repo contains a `package.json` in a sub-folder, adjust APP_DIR accordingly
# Example: if files are under repo/server/, do:
# APP_DIR="$APP_DIR/server"
# cd "$APP_DIR"

# 6. Install Node dependencies & PM2 globally
npm ci   # respects package-lock.json
npm install -g pm2

# 7. Render NGINX config (uses the variables above)
cat >"$NGINX_CONF" <<EOF
worker_processes auto;
events { worker_connections 1024; }

rtmp {
    server {
        listen 1935;
        chunk_size 4096;

        application live {
            live on;
            record off;

            hls on;
            hls_path $HLS_DIR;
            hls_fragment 3s;
            hls_playlist_length 60s;

            # Adaptive bitrates (720p + 480p)
            exec_push ffmpeg -i rtmp://localhost/live/\$name
                -c:v libx264 -preset veryfast -b:v 3000k -maxrate 3000k -bufsize 6000k -vf "scale=1280:720" -g 60 -r 30 -f flv rtmp://localhost/hls/\$name_720p
                -c:v libx264 -preset veryfast -b:v 1500k -maxrate 1500k -bufsize 3000k -vf "scale=854:480"  -g 60 -r 30 -f flv rtmp://localhost/hls/\$name_480p;
        }

        application hls {
            live on;
            hls on;
            hls_path $HLS_DIR;
            hls_nested on;
        }
    }
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    server {
        listen 80;
        server_name $SERVER_DOMAIN_OR_IP;

        # Serve HLS segments
        location /hls {
            types {
                application/vnd.apple.mpegurl m3u8;
                video/mp2t ts;
            }
            root /var/www/html;
            add_header Cache-Control no-cache;
            add_header Access-Control-Allow-Origin *;
        }

        # Proxy everything else to Node.js
        location / {
            proxy_pass http://127.0.0.1:$NODE_PORT;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
}
EOF

# 8. If your repo already ships its own nginx.conf, overwrite with it:
if [ -f "$APP_DIR/nginx.conf" ]; then
    echo "Repo provides its own nginx.conf – using it."
    cp "$APP_DIR/nginx.conf" "$NGINX_CONF"
fi

# 9. Test NGINX config
nginx -t

# 10. Start NGINX
systemctl restart nginx

# 11. Start Node.js app with PM2
#   - assumes the entry point is `app.js` (or `server.js`)
ENTRY_FILE=$(node -e "console.log(require('./package.json').main || 'app.js')")
pm2 start "$ENTRY_FILE" --name streaming-app
pm2 startup systemd -u $(whoami) --hp /home/$(whoami)
pm2 save

# 12. Firewall (GCP already has its own firewall, but ufw is nice locally)
ufw allow 80/tcp
ufw allow 1935/tcp
ufw --force enable

# ------------------------------------------------------------
# DONE
# ------------------------------------------------------------
echo "===================================="
echo "Setup complete!"
echo ""
echo "Teacher page : http://$SERVER_DOMAIN_OR_IP/teacher"
echo "Viewer page  : http://$SERVER_DOMAIN_OR_IP/viewer"
echo "RTMP ingest  : rtmp://$SERVER_DOMAIN_OR_IP/live/$STREAM_KEY"
echo ""
echo "Check logs:"
echo "  NGINX : journalctl -u nginx"
echo "  Node  : pm2 logs streaming-app"
echo "===================================="