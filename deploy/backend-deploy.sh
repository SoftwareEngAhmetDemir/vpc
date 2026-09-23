#!/usr/bin/env bash
# Run this ON the backend EC2 instance (private subnet), via SSM Session Manager.
set -euo pipefail

REPO_URL="${REPO_URL:?set REPO_URL to your git repo, e.g. https://github.com/you/vpc-demo.git}"
RDS_ENDPOINT="${RDS_ENDPOINT:?set RDS_ENDPOINT to the RDS instance endpoint from the console}"
DB_PASSWORD="${DB_PASSWORD:?set DB_PASSWORD to the RDS master password}"
DB_NAME="${DB_NAME:-vpcdemo}"
DB_USER="${DB_USER:-postgres}"
APP_DIR="$HOME/app"

sudo dnf install -y nodejs git postgresql16

if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" pull
else
  git clone "$REPO_URL" "$APP_DIR"
fi
cd "$APP_DIR/backend"
npm install

cat > .env <<EOF
PORT=3001
DB_HOST=${RDS_ENDPOINT}
DB_PORT=5432
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=${DB_NAME}
DB_SSL=true
EOF

psql "host=${RDS_ENDPOINT} port=5432 dbname=${DB_NAME} user=${DB_USER} password=${DB_PASSWORD} sslmode=require" -f schema.sql

sudo npm install -g pm2
pm2 delete backend 2>/dev/null || true
pm2 start server.js --name backend
pm2 startup systemd -u "$(whoami)" --hp "$HOME" | tail -1 | sudo bash || true
pm2 save

TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
echo "Backend running. Private IP:"
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4; echo
echo "Test with: curl http://localhost:3001/api/health"
