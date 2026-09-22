#!/usr/bin/env bash
# Run this ON the backend EC2 instance (private subnet), via SSM Session Manager.
# Fill in the 4 values below before running, or export them first.
set -euo pipefail

REPO_URL="${REPO_URL:?set REPO_URL to your git repo, e.g. https://github.com/you/vpc-demo.git}"
RDS_ENDPOINT="${RDS_ENDPOINT:?set RDS_ENDPOINT to the RDS instance endpoint from the console}"
DB_PASSWORD="${DB_PASSWORD:?set DB_PASSWORD to the RDS master password}"
DB_NAME="${DB_NAME:-vpcdemo}"
DB_USER="${DB_USER:-postgres}"

sudo dnf install -y nodejs git postgresql16

if [ ! -d app ]; then
  git clone "$REPO_URL" app
fi
cd app && git pull
cd backend
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

echo "Backend running. Private IP:"
curl -s http://169.254.169.254/latest/meta-data/local-ipv4; echo
echo "Test with: curl http://localhost:3001/api/health"
