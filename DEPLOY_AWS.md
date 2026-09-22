# Deploying to AWS: VPC walkthrough (Console)

Goal architecture:

```
                         Internet
                             │
                      Internet Gateway
                             │
   ┌─────────────────────────────────────────────────────┐
   │  VPC  10.0.0.0/16                                    │
   │                                                       │
   │   PUBLIC SUBNET A (10.0.1.0/24, AZ-a)                 │
   │   ┌───────────────────────────────┐   ┌────────────┐ │
   │   │ EC2: frontend (nginx + React) │   │ NAT Gateway│ │
   │   │ public IP, SG: frontend-sg    │   └─────┬──────┘ │
   │   └───────────────┬───────────────┘         │        │
   │                   │ proxies /api/*           │        │
   │                   ▼                          │        │
   │   PRIVATE SUBNET A (10.0.11.0/24, AZ-a)       │        │
   │   ┌───────────────────────────────┐          │        │
   │   │ EC2: backend (Express)        │◄─────────┘        │
   │   │ no public IP, SG: backend-sg  │                    │
   │   └───────────────┬───────────────┘                    │
   │                   │                                     │
   │                   ▼                                     │
   │   ┌───────────────────────────────┐                     │
   │   │ RDS PostgreSQL, SG: db-sg     │                     │
   │   └───────────────────────────────┘                     │
   │   PRIVATE SUBNET B (10.0.12.0/24, AZ-b) — 2nd AZ for RDS │
   └─────────────────────────────────────────────────────────┘
```

Everything below is done in the AWS Console. Pick one region (e.g. `us-east-1`) and stay in it for every step. Replace placeholder IPs/IDs with the real ones AWS gives you as you go — write them down somewhere as you create each resource, you'll need them repeatedly.

Estimated cost while running: NAT Gateway (~$0.045/hr + data) and RDS/EC2 (t3.micro-class, free-tier eligible on a new account) are the main costs. **Delete the NAT Gateway, RDS instance, and EC2 instances when you're done experimenting** (see teardown section) — the NAT Gateway in particular bills hourly even when idle.

---

## 1. Create the VPC and subnets

1. Console → **VPC** → **Your VPCs** → **Create VPC**.
2. Choose **VPC only** (not the wizard — you'll build subnets by hand to understand each piece).
   - Name: `vpc-demo`
   - IPv4 CIDR: `10.0.0.0/16`
   - Leave IPv6 and tenancy as default.
3. Create VPC.
4. Go to **Subnets** → **Create subnet**, VPC = `vpc-demo`. Create four, one at a time:

   | Name | AZ | CIDR |
   |---|---|---|
   | `public-a` | us-east-1a | `10.0.1.0/24` |
   | `public-b` | us-east-1b | `10.0.2.0/24` |
   | `private-a` | us-east-1a | `10.0.11.0/24` |
   | `private-b` | us-east-1b | `10.0.12.0/24` |

   (Two public subnets aren't strictly required for a single EC2 frontend, but RDS *requires* a subnet group spanning ≥2 AZs, so `private-b` is mandatory. `public-b` is included for symmetry/future use, e.g. if you later add a load balancer.)

5. Select `public-a` and `public-b` → **Actions → Edit subnet settings** → enable **Auto-assign public IPv4 address**. Leave the private subnets with this off.

## 2. Internet Gateway (public subnet → internet)

1. **VPC → Internet Gateways → Create internet gateway**. Name: `vpc-demo-igw`. Create.
2. Select it → **Actions → Attach to VPC** → choose `vpc-demo`.

## 3. Route table for public subnets

1. **VPC → Route Tables → Create route table**. Name: `public-rt`, VPC: `vpc-demo`.
2. Select it → **Routes** tab → **Edit routes** → **Add route**: destination `0.0.0.0/0`, target = the `vpc-demo-igw` internet gateway. Save.
3. **Subnet associations** tab → **Edit subnet associations** → check `public-a` and `public-b`. Save.

## 4. NAT Gateway (private subnet → internet, one-way)

Private instances need outbound internet (OS/package updates, npm installs, reaching AWS Systems Manager) but must not be reachable from the internet. A NAT Gateway does that.

1. **VPC → NAT Gateways → Create NAT gateway**.
   - Name: `vpc-demo-nat`
   - Subnet: `public-a` (NAT gateways live in a **public** subnet)
   - Connectivity type: **Public**
   - Elastic IP: click **Allocate Elastic IP** to create one on the spot.
2. Create. Wait until its state is **Available** (a few minutes) before continuing.

## 5. Route table for private subnets

1. **VPC → Route Tables → Create route table**. Name: `private-rt`, VPC: `vpc-demo`.
2. **Edit routes** → **Add route**: destination `0.0.0.0/0`, target = the `vpc-demo-nat` NAT gateway. Save.
3. **Subnet associations** → check `private-a` and `private-b`. Save.

At this point: public subnets route to the internet directly via the IGW; private subnets route out via the NAT gateway and cannot be reached from the internet inbound.

## 6. Security groups

**VPC → Security Groups → Create security group**, all in `vpc-demo`. Create them in this order so you can reference each one when creating the next.

1. **`frontend-sg`**
   - Inbound: HTTP (80) from `0.0.0.0/0`. Add SSH (22) from **My IP** only if you plan to SSH in directly (optional — see SSM note below).
   - Outbound: default (all traffic) — leave as-is.

2. **`backend-sg`**
   - Inbound: Custom TCP, port `3001`, source = `frontend-sg` (select the security group itself as the source, not a CIDR).
   - Outbound: default (all traffic).

3. **`db-sg`**
   - Inbound: PostgreSQL (5432), source = `backend-sg`.
   - Outbound: default.

This is the enforcement of your architecture: only the frontend can talk to the backend, and only the backend can talk to the database. Nothing reaches the database or backend directly from the internet.

## 7. IAM role for SSM (so you can reach the private backend instance without SSH/bastion)

1. **IAM → Roles → Create role**.
2. Trusted entity: **AWS service** → **EC2**.
3. Attach policy: `AmazonSSMManagedInstanceCore`.
4. Name: `ec2-ssm-role`. Create.

You'll attach this to the backend (and optionally frontend) EC2 instance at launch — it lets you open a shell via **Systems Manager Session Manager** in the console instead of needing SSH keys or a bastion host reachable from the internet.

## 8. RDS PostgreSQL (private)

1. **RDS → Subnet groups → Create DB subnet group**.
   - Name: `vpc-demo-db-subnets`, VPC: `vpc-demo`.
   - Add subnets: `private-a` and `private-b`.
2. **RDS → Databases → Create database**.
   - Engine: **PostgreSQL**.
   - Templates: **Free tier** (or Dev/Test).
   - DB instance identifier: `vpc-demo-db`
   - Master username: `postgres`, set a strong master password (save it).
   - Instance class: `db.t3.micro` (or whatever free tier offers).
   - Storage: default (20 GiB gp3 is fine).
   - **Connectivity**: VPC = `vpc-demo`; DB subnet group = `vpc-demo-db-subnets`; **Public access = No**; VPC security group = choose existing → `db-sg` (remove the default one).
   - Initial database name: `vpcdemo`.
   - Leave the rest default. Create database. It takes several minutes.
3. Once available, note the **endpoint** (hostname) shown on the DB's detail page — you'll use it as `DB_HOST` on the backend.

## 9. Launch the backend EC2 instance (private subnet)

1. **EC2 → Instances → Launch instance**.
   - Name: `backend`
   - AMI: **Amazon Linux 2023**
   - Instance type: `t3.micro`
   - Key pair: you can select "Proceed without a key pair" since you'll use SSM to connect.
   - Network settings → Edit:
     - VPC: `vpc-demo`
     - Subnet: `private-a`
     - Auto-assign public IP: **Disable**
     - Security group: select existing → `backend-sg`
   - Advanced details → IAM instance profile: `ec2-ssm-role`.
2. Launch.
3. Once running, select the instance → **Connect** → **Session Manager** tab → **Connect**. This opens a browser-based shell — no SSH key or public IP needed.
4. In that shell, install Node.js and get the app onto the box:

   ```bash
   sudo dnf install -y nodejs git
   node -v
   git clone <your-repo-url> app   # or upload the backend/ folder another way (e.g. `aws s3 cp` from an S3 bucket)
   cd app/backend
   npm install
   ```

5. Create `backend/.env` on the instance (use `nano .env`):

   ```
   PORT=3001
   DB_HOST=<the RDS endpoint from step 8.3>
   DB_PORT=5432
   DB_USER=postgres
   DB_PASSWORD=<the master password you set>
   DB_NAME=vpcdemo
   DB_SSL=true
   ```

6. Load the schema against RDS. Easiest way from this box:

   ```bash
   sudo dnf install -y postgresql16
   psql "host=<rds-endpoint> port=5432 dbname=vpcdemo user=postgres password=<password> sslmode=require" -f schema.sql
   ```

7. Run the API as a background service so it survives logout/reboot:

   ```bash
   sudo npm install -g pm2
   pm2 start server.js --name backend
   pm2 startup   # follow the printed command to enable on boot
   pm2 save
   ```

8. Note this instance's **private IPv4 address** (Instance summary in the console) — you'll need it for the nginx config on the frontend.

## 10. Launch the frontend EC2 instance (public subnet)

1. **EC2 → Instances → Launch instance**.
   - Name: `frontend`
   - AMI: **Amazon Linux 2023**, type `t3.micro`
   - Key pair: create/select one if you want direct SSH (optional, since it's public you can also use SSM here too).
   - Network settings → Edit:
     - VPC: `vpc-demo`, Subnet: `public-a`
     - Auto-assign public IP: **Enable**
     - Security group: existing → `frontend-sg`
   - IAM instance profile: `ec2-ssm-role` (optional, so you can also use SSM instead of SSH).
2. Launch. Note its **public IPv4 address** once running.
3. Connect (Session Manager or SSH) and install nginx + Node (Node only needed to *build* the React app; you can also build locally and upload just the `dist/` folder):

   ```bash
   sudo dnf install -y nginx nodejs git
   sudo systemctl enable --now nginx
   git clone <your-repo-url> app
   cd app/frontend
   ```

4. Point the build at the backend via the reverse proxy (same-origin), then build:

   ```bash
   echo "VITE_API_URL=" > .env.production
   npm install
   npm run build
   ```

5. Deploy the build output and configure nginx:

   ```bash
   sudo mkdir -p /var/www/vpc-demo
   sudo cp -r dist /var/www/vpc-demo/
   sudo cp nginx.conf.example /etc/nginx/conf.d/vpc-demo.conf
   sudo sed -i "s/BACKEND_PRIVATE_IP/<backend private IP from step 9.8>/" /etc/nginx/conf.d/vpc-demo.conf
   sudo rm -f /etc/nginx/conf.d/default.conf   # avoid conflicting default site, if present
   sudo nginx -t && sudo systemctl reload nginx
   ```

## 11. Test it

Open `http://<frontend public IP>` in a browser. You should see "Hello World" and the 3 seeded items — proving the full path: **browser → frontend EC2 (public subnet) → nginx proxy → backend EC2 (private subnet) → RDS (private subnet)**.

Things to check if it doesn't work:
- `curl http://localhost/api/items` from the frontend box — tests the nginx proxy → backend hop.
- `curl http://<backend-private-ip>:3001/api/health` from the frontend box — tests frontend-sg → backend-sg connectivity directly.
- `pm2 logs backend` on the backend box — check for DB connection errors (bad password, security group, or `DB_SSL` mismatch).
- Security group rules — the single most common mistake is referencing a CIDR instead of the security group ID as the source.

## 12. Teardown (avoid ongoing charges)

Delete in this order: EC2 instances (backend, frontend) → RDS instance (`vpc-demo-db`, skip final snapshot if you don't need one) → NAT Gateway (`vpc-demo-nat`) → release the Elastic IP → delete route tables, subnets, internet gateway, then the VPC itself. The NAT Gateway and any Elastic IP left allocated are the two things that quietly keep costing money if forgotten.

---

## Notes / next steps

- This uses **EC2 + SSM** for the private backend to avoid needing a bastion host — simplest way to poke around a private subnet from the console.
- For anything beyond a demo, put an **Application Load Balancer** in the public subnets in front of the frontend (and optionally in front of the backend too, private-facing), rather than exposing EC2 instances directly — it gives you health checks, TLS termination, and easy horizontal scaling.
- Store `DB_PASSWORD` in **AWS Secrets Manager** instead of a plaintext `.env` once this becomes more than a demo.
- If you outgrow "click through the console," this whole setup (VPC, subnets, route tables, security groups, EC2, RDS) is a natural fit for Terraform or CloudFormation — ask if you want that version once you're comfortable with the manual steps.
