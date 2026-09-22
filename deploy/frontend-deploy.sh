#!/usr/bin/env bash
# Run this ON the frontend EC2 instance (public subnet), via SSM or SSH.
# Fill in the 2 values below before running, or export them first.
set -euo pipefail

REPO_URL="${REPO_URL:?set REPO_URL to your git repo, e.g. https://github.com/you/vpc-demo.git}"
BACKEND_PRIVATE_IP="${BACKEND_PRIVATE_IP:?set BACKEND_PRIVATE_IP to the backend EC2 private IP from the console (or backend-deploy.sh output)}"

sudo dnf install -y nginx nodejs git
sudo systemctl enable --now nginx

if [ ! -d app ]; then
  git clone "$REPO_URL" app
fi
cd app && git pull
cd frontend
echo "VITE_API_URL=" > .env.production
npm install
npm run build

sudo mkdir -p /var/www/vpc-demo
sudo rm -rf /var/www/vpc-demo/dist
sudo cp -r dist /var/www/vpc-demo/

sudo sed "s/BACKEND_PRIVATE_IP/${BACKEND_PRIVATE_IP}/" nginx.conf.example | sudo tee /etc/nginx/conf.d/vpc-demo.conf > /dev/null
sudo rm -f /etc/nginx/conf.d/default.conf
sudo nginx -t
sudo systemctl reload nginx

echo "Frontend deployed. Public IP:"
curl -s http://169.254.169.254/latest/meta-data/public-ipv4; echo
echo "Open it in a browser, or test with: curl http://localhost/api/items"
