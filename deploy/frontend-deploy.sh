#!/usr/bin/env bash
# Run this ON the frontend EC2 instance (public subnet), via SSM or SSH.
# nginx serves the built React app and proxies /api/* to the backend's private IP.
set -euo pipefail

REPO_URL="${REPO_URL:?set REPO_URL to your git repo, e.g. https://github.com/you/vpc-demo.git}"
BACKEND_PRIVATE_IP="${BACKEND_PRIVATE_IP:?set BACKEND_PRIVATE_IP to the backend EC2 private IP from the console}"
APP_DIR="$HOME/app"

sudo dnf install -y nginx nodejs git
sudo systemctl enable --now nginx

if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" pull
else
  git clone "$REPO_URL" "$APP_DIR"
fi
cd "$APP_DIR/frontend"
npm install
npm run build

sudo mkdir -p /var/www/vpc-demo
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
sudo sed "s/BACKEND_PRIVATE_IP/${BACKEND_PRIVATE_IP}/" nginx.conf.example | sudo tee /etc/nginx/conf.d/vpc-demo.conf > /dev/null
sudo nginx -t
sudo systemctl reload nginx

sleep 1
curl -fsS -o /dev/null http://localhost/
curl -fsS http://localhost/api/items > /dev/null

TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
echo "Frontend deployed. Public IP:"
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4; echo
echo "Test with: curl http://localhost/api/items"
