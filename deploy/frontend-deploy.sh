#!/usr/bin/env bash
# Run this ON the frontend EC2 instance (public subnet), via SSM or SSH.
# nginx serves the built React app and proxies /api/* to the backend's private IP, and serves HTTPS.
#
# Certificate modes:
#   default (DOMAIN unset): a Let's Encrypt IP-address certificate for this instance's public IP, so
#     https://<public-ip>/ works with no redirect. These certificates last ~6 days; renewal is automatic
#     and briefly stops nginx (a few seconds) because certbot must use its standalone mode for IPs.
#     Needs certbot >= 5.3.0. A new public IP (for example after associating an Elastic IP) gets a
#     new certificate on the next deploy.
#   DOMAIN=app.example.com: a normal certificate for that hostname (must resolve to this instance);
#     HTTP is then redirected to https://<DOMAIN>.
# Port 80 (challenge) and 443 (visitors) must be open in frontend-sg.
#
# Optional env vars: DOMAIN, CERT_EMAIL (expiry notices; default none)
set -euo pipefail

REPO_URL="${REPO_URL:?set REPO_URL to your git repo, e.g. https://github.com/you/vpc-demo.git}"
BACKEND_PRIVATE_IP="${BACKEND_PRIVATE_IP:?set BACKEND_PRIVATE_IP to the backend EC2 private IP from the console}"
DOMAIN="${DOMAIN:-}"
CERT_EMAIL="${CERT_EMAIL:-}"
APP_DIR="$HOME/app"
CERT_NAME=""

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
  sed -e "s/BACKEND_PRIVATE_IP/${BACKEND_PRIVATE_IP}/g" \
      -e "s/__DOMAIN__/${DOMAIN}/g" \
      -e "s/__CERT_NAME__/${CERT_NAME}/g" "$1" |
    sudo tee /etc/nginx/conf.d/vpc-demo.conf > /dev/null
  sudo nginx -t
  sudo systemctl reload nginx
}

TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4 || true)
if [ -z "$DOMAIN" ] && [ -z "$PUBLIC_IP" ]; then
  echo "No DOMAIN given and no public IP found"
  exit 1
fi

ensure_certbot() {
  local cur=""
  if [ -x /opt/certbot/bin/certbot ]; then
    cur=$(/opt/certbot/bin/certbot --version 2>&1 | awk '{print $2}' || true)
  fi
  if [ -n "$cur" ] && [ "$(printf '%s\n5.3.0\n' "$cur" | sort -V | head -n1)" = "5.3.0" ]; then
    return 0
  fi
  # Older certbot (or none): rebuild with the newest Python available; IP certificates need >= 5.3.0.
  sudo dnf install -y python3.12 >/dev/null 2>&1 || sudo dnf install -y python3.11 >/dev/null 2>&1 || true
  local py
  py=$(command -v python3.12 || command -v python3.11 || command -v python3)
  sudo rm -rf /opt/certbot
  sudo "$py" -m venv /opt/certbot
  sudo /opt/certbot/bin/pip install --quiet --upgrade pip certbot
  sudo ln -sf /opt/certbot/bin/certbot /usr/local/bin/certbot
}
ensure_certbot
echo "certbot $(/opt/certbot/bin/certbot --version 2>&1)"

EMAIL_ARGS=(--register-unsafely-without-email)
[ -n "$CERT_EMAIL" ] && EMAIL_ARGS=(-m "$CERT_EMAIL")

# Keep any working config in place; only create the plain HTTP site if nothing exists yet.
if [ ! -f /etc/nginx/conf.d/vpc-demo.conf ]; then
  render nginx.conf.example
fi

CERT_OK=1
if [ -n "$DOMAIN" ]; then
  CERT_NAME="$DOMAIN"
  render nginx.conf.example
  if [ ! -d "/etc/letsencrypt/live/$CERT_NAME" ]; then
    sudo /opt/certbot/bin/certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" \
      --non-interactive --agree-tos "${EMAIL_ARGS[@]}" || CERT_OK=0
  fi
  if [ "$CERT_OK" = 1 ]; then
    render nginx-ssl.conf.example
  fi
  SITE_URL="https://$DOMAIN/"
else
  CERT_NAME="ip-${PUBLIC_IP}"
  if [ ! -d "/etc/letsencrypt/live/$CERT_NAME" ]; then
    sudo /opt/certbot/bin/certbot certonly --standalone --ip-address "$PUBLIC_IP" \
      --preferred-profile shortlived --cert-name "$CERT_NAME" \
      --non-interactive --agree-tos "${EMAIL_ARGS[@]}" \
      --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx" || CERT_OK=0
  fi
  if [ "$CERT_OK" = 1 ]; then
    render nginx-ip.conf.example
    # Drop certificates from earlier setups (for example the sslip.io one); nothing uses them now.
    for old in $(sudo ls /etc/letsencrypt/live 2>/dev/null | grep -vx -e README -e "$CERT_NAME" || true); do
      sudo /opt/certbot/bin/certbot delete --cert-name "$old" --non-interactive || true
    done
    # Renewal happens every few days, so prove it works now instead of finding out in a week.
    if ! sudo /opt/certbot/bin/certbot renew --cert-name "$CERT_NAME" --dry-run; then
      echo "WARNING: certificate renewal dry-run failed; the certificate will expire in about 6 days."
      CERT_OK=0
    fi
  fi
  SITE_URL="https://${PUBLIC_IP}/"
fi

if [ "$CERT_OK" = 1 ] || [ -d "/etc/letsencrypt/live/$CERT_NAME" ]; then
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
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now certbot-renew.timer
fi

sleep 1
sudo systemctl is-active --quiet nginx
curl -fsS http://localhost/api/items > /dev/null || curl -fsSL -k http://localhost/api/items > /dev/null
if [ "$CERT_OK" = 1 ]; then
  curl -fsSk https://localhost/api/items > /dev/null
  echo "Frontend deployed: $SITE_URL"
else
  echo "Frontend deployed, but HTTPS setup FAILED. The site still works over whatever config was already active."
  echo "Check: port 80 and 443 open in frontend-sg, and (IP mode) certbot >= 5.3.0. Log: /var/log/letsencrypt/letsencrypt.log"
  exit 1
fi
