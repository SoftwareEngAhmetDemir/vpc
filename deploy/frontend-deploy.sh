#!/usr/bin/env bash
# Run this ON the frontend EC2 instance (public subnet), via SSM or SSH.
# The Node frontend server fetches data from the private backend; nginx only exposes that server.
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

sudo npm install -g pm2
pm2 delete frontend 2>/dev/null || true
BACKEND_URL="http://${BACKEND_PRIVATE_IP}:3001" pm2 start server.js --name frontend
pm2 startup systemd -u "$(whoami)" --hp "$HOME" | tail -1 | sudo bash || true
pm2 save

# AL2023's nginx.conf ships its own default server block that shadows conf.d/*.conf.
sudo sed -i '/^    server {$/,/^    }$/d' /etc/nginx/nginx.conf
sudo rm -f /etc/nginx/conf.d/default.conf
sudo cp nginx.conf.example /etc/nginx/conf.d/vpc-demo.conf
sudo nginx -t
sudo systemctl reload nginx

sleep 2
curl -fsS -o /dev/null http://localhost/

TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
echo "Frontend deployed. Public IP:"
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4; echo
echo "Test with: curl http://localhost/   (items are embedded in the HTML; /api/* returns 404)"
