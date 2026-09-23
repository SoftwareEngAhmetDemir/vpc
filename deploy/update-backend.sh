#!/usr/bin/env bash
# Run on the backend EC2 as the app user (ssm-user) after the repo has been updated.
# Installs dependencies and restarts the API. Does not touch backend/.env or the database.
set -euo pipefail

cd "$(dirname "$0")/../backend"
npm install
pm2 restart backend || pm2 start server.js --name backend
pm2 save

sleep 2
curl -fsS http://localhost:3001/api/health
echo
