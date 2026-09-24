#!/usr/bin/env bash
# Run this ON the frontend EC2 instance (public subnet), via SSM or SSH.
# nginx serves the built React app and proxies /api/* to the backend's private IP.
# It also gets a free Let's Encrypt certificate and serves HTTPS (needs port 80 open for the
# challenge and port 443 open in frontend-sg for visitors).
#
# Optional env vars:
#   DOMAIN       hostname that points at this instance (default: <public-ip-with-dashes>.sslip.io)
#   CERT_EMAIL   email for Let's Encrypt expiry notices (default: none)
set -euo pipefail

REPO_URL="${REPO_URL:?set REPO_URL to your git repo, e.g. https://github.com/you/vpc-demo.git}"
BACKEND_PRIVATE_IP="${BACKEND_PRIVATE_IP:?set BACKEND_PRIVATE_IP to the backend EC2 private IP from the console}"
DOMAIN="${DOMAIN:-}"
CERT_EMAIL="${CERT_EMAIL:-}"
APP_DIR="$HOME/app"

sudo dnf install -y nginx nodejs git python3-pip
sudo systemctl enable --now nginx

if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" pull
else
  git clone "$REPO_URL" "$APP_DIR"
fi
cd "$APP_DIR/frontend"
npm install
npm run build

sudo mkdir -p /var/www/vpc-demo /var/www/certbot
sudo rm -rf /var/www/vpc-demo/dist
sudo cp -r dist /var/www/vpc-demo/

# Earlier versions ran a Node frontend server under pm2; it is no longer used.
if command -v pm2 >/dev/null 2>&1; then
  pm2 delete frontend 2>/dev/null || true
  pm2 save --force >/dev/null 2>&1 || true
fi

# AL2023's nginx.conf ships its own default server block that shadows conf.d/*.conf.
sudo sed -i '/^    server {$/,/^    }$/d' /etc/nginx/nginx.conf
sudo rm -f /etc/nginx/conf.d/default.conf

render() {
  sed -e "s/BACKEND_PRIVATE_IP/${BACKEND_PRIVATE_IP}/g" -e "s/__DOMAIN__/${DOMAIN}/g" "$1" |
    sudo tee /etc/nginx/conf.d/vpc-demo.conf > /dev/null
  sudo nginx -t
  sudo systemctl reload nginx
}

TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4 || true)
if [ -z "$DOMAIN" ]; then
  [ -n "$PUBLIC_IP" ] || { echo "No DOMAIN given and no public IP found"; exit 1; }
  DOMAIN="${PUBLIC_IP//./-}.sslip.io"
fi
echo "Using hostname: $DOMAIN (public IP: ${PUBLIC_IP:-none})"

# HTTP-only site first: it serves the challenge path certbot needs, and is the fallback.
render nginx.conf.example

HTTPS_OK=1
if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  if [ ! -x /opt/certbot/bin/certbot ]; then
    sudo python3 -m venv /opt/certbot
    sudo /opt/certbot/bin/pip install --quiet --upgrade pip certbot
    sudo ln -sf /opt/certbot/bin/certbot /usr/local/bin/certbot
  fi
  EMAIL_ARGS=(--register-unsafely-without-email)
  [ -n "$CERT_EMAIL" ] && EMAIL_ARGS=(-m "$CERT_EMAIL")
  if ! sudo /opt/certbot/bin/certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" \
    --non-interactive --agree-tos "${EMAIL_ARGS[@]}"; then
    HTTPS_OK=0
  fi
fi

if [ "$HTTPS_OK" = 1 ]; then
  render nginx-ssl.conf.example

  sudo tee /etc/systemd/system/certbot-renew.service > /dev/null <<'UNIT'
[Unit]
Description=Renew Let's Encrypt certificates

[Service]
Type=oneshot
ExecStart=/opt/certbot/bin/certbot renew --quiet --deploy-hook "systemctl reload nginx"
UNIT
  sudo tee /etc/systemd/system/certbot-renew.timer > /dev/null <<'UNIT'
[Unit]
Description=Twice-daily Let's Encrypt renewal check

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now certbot-renew.timer
fi

sleep 1
if [ "$HTTPS_OK" = 1 ]; then
  curl -fsSk https://localhost/api/items > /dev/null
  echo "Frontend deployed: https://$DOMAIN/"
else
  curl -fsS http://localhost/api/items > /dev/null
  echo "Frontend deployed over HTTP only: http://${PUBLIC_IP:-<public-ip>}/"
  echo "WARNING: could not get a certificate for $DOMAIN. Check that port 80 is reachable from the internet and that $DOMAIN resolves to this instance."
  exit 1
fi
