# vpc-demo

Minimal "hello world" full-stack app: React (Vite) frontend, Node/Express backend, PostgreSQL database.
Built to be deployed into an AWS VPC with the frontend in a **public subnet** and the backend + database in a **private subnet** — see [DEPLOY_AWS.md](DEPLOY_AWS.md) for the full walkthrough.

## Structure

```
frontend/   React app (Vite). The browser calls /api/items on its own origin; nginx proxies that to the backend.
backend/    Express API. GET /api/items reads from PostgreSQL. GET /api/health for checks.
docker-compose.yml   Local PostgreSQL for development.
DEPLOY_AWS.md         Step-by-step AWS Console guide: VPC, subnets, EC2, RDS.
```

## Run it locally

1. Start a local Postgres (requires Docker Desktop running):

   ```
   docker compose up -d
   ```

   This creates a `vpcdemo` database and seeds an `items` table (see `backend/schema.sql`).

   No Docker? Install Postgres locally and run `psql -f backend/schema.sql` against a `vpcdemo` database instead.

2. Backend:

   ```
   cd backend
   cp .env.example .env   # already points at localhost:5432
   npm install
   npm run dev
   ```

   Verify: `curl http://localhost:3001/api/items`

3. Frontend (separate terminal):

   ```
   cd frontend
   cp .env.example .env   # VITE_API_URL=http://localhost:3001
   npm install
   npm run dev
   ```

   Open the printed URL (usually http://localhost:5173) — you should see "Hello World" and a list of 3 items.

## Deploying to AWS

See [DEPLOY_AWS.md](DEPLOY_AWS.md). Summary of the target architecture:

- **VPC** with 2 public subnets (different AZs) and 2 private subnets (different AZs)
- **Public subnet**: frontend EC2 (nginx serves the React build and reverse-proxies `/api/*` to the backend)
- **Private subnet**: backend EC2 (Express API, no public IP, reached only via SSM) and RDS PostgreSQL (not publicly accessible)
- **NAT Gateway** in the public subnet so private instances can reach the internet (package installs) without being reachable from it
- **Security groups** scoped tightly: internet → frontend (80), frontend-sg → backend (3001), backend-sg → db (5432)
