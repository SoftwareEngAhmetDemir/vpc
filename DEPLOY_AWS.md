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
4. Push [deploy/backend-deploy.sh](deploy/backend-deploy.sh) onto the box (paste its contents into `nano backend-deploy.sh`, or `git clone` your repo first and run it from there), then run it with the values from earlier steps:

   ```bash
   REPO_URL=https://github.com/<you>/<repo>.git \
   RDS_ENDPOINT=<the RDS endpoint from step 8.3> \
   DB_PASSWORD=<the master password you set> \
   bash backend-deploy.sh
   ```

   This installs Node/git/psql, clones the repo, writes `backend/.env`, loads `schema.sql` into RDS, and runs the API under `pm2` (auto-restarts on crash/reboot). It prints the instance's private IP at the end — note it for the frontend step.

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
3. Connect (Session Manager or SSH), then push [deploy/frontend-deploy.sh](deploy/frontend-deploy.sh) onto the box the same way as the backend script, and run it:

   ```bash
   REPO_URL=https://github.com/<you>/<repo>.git \
   BACKEND_PRIVATE_IP=<backend private IP from step 9.4's output> \
   bash frontend-deploy.sh
   ```

   This installs nginx/Node/git, clones the repo, builds the React app (`VITE_API_URL` empty, so the browser calls `/api/items` on the same origin), copies the build to `/var/www/vpc-demo`, and writes an nginx config that serves it and proxies `/api/*` to the backend's private IP. It also removes AL2023's built-in default nginx server block, which would otherwise shadow ours and return 404.

## 11. Test it

Open `http://<frontend public IP>` in a browser. You should see "Hello World" and the 3 seeded items — proving the full path: **browser → frontend EC2 (public subnet) → nginx proxy → backend EC2 (private subnet) → RDS (private subnet)**.

Things to check if it doesn't work:
- `curl http://localhost/api/items` from the frontend box — tests the nginx proxy → backend hop.
- `sudo tail /var/log/nginx/error.log` on the frontend box — a `connect() failed` line means nginx can't reach the backend (check `backend-sg`).
- `curl http://<backend-private-ip>:3001/api/health` from the frontend box — tests frontend-sg → backend-sg connectivity directly.
- `pm2 logs backend` on the backend box — check for DB connection errors (bad password, security group, or `DB_SSL` mismatch).
- Security group rules — the single most common mistake is referencing a CIDR instead of the security group ID as the source.

## 12. Teardown (avoid ongoing charges)

Delete in this order: EC2 instances (backend, frontend) → RDS instance (`vpc-demo-db`, skip final snapshot if you don't need one) → NAT Gateway (`vpc-demo-nat`) → release the Elastic IP → delete route tables, subnets, internet gateway, then the VPC itself. The NAT Gateway and any Elastic IP left allocated are the two things that quietly keep costing money if forgotten.

---

## 13. CI/CD with GitHub Actions (optional)

[.github/workflows/deploy.yml](.github/workflows/deploy.yml) runs on every push: CI builds and checks the code, then (on `main` only) CD deploys to both instances through **SSM Run Command**. GitHub logs in to AWS with **OIDC**, so no access keys are stored anywhere. The deploy job is skipped until the variable `AWS_ROLE_ARN` exists.

Do this once in the Console (region eu-north-1 for the policy resource ARNs; IAM itself is global):

1. **IAM → Identity providers → Add provider**: type **OpenID Connect**, provider URL `https://token.actions.githubusercontent.com`, audience `sts.amazonaws.com`. Add provider.
2. **IAM → Policies → Create policy → JSON**, name `github-deploy-ssm`:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": "ssm:SendCommand",
         "Resource": [
           "arn:aws:ec2:eu-north-1:087134855638:instance/<backend-instance-id>",
           "arn:aws:ec2:eu-north-1:087134855638:instance/<frontend-instance-id>",
           "arn:aws:ssm:eu-north-1::document/AWS-RunShellScript"
         ]
       },
       {
         "Effect": "Allow",
         "Action": ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"],
         "Resource": "*"
       }
     ]
   }
   ```

3. **IAM → Roles → Create role**: trusted entity **Web identity**, provider `token.actions.githubusercontent.com`, audience `sts.amazonaws.com`, GitHub organization `SoftwareEngAhmetDemir`, repository `vpc`, branch `main`. Attach `github-deploy-ssm`. Name it `github-deploy-role`. The branch restriction matters because the repo is public: only runs of `main` in this repo can assume the role.

   **Then edit the trust policy.** New GitHub repos put their numeric IDs in the token subject, so the wizard's plain-name `sub` is rejected ("Not authorized to perform sts:AssumeRoleWithWebIdentity"). Get the real prefix with `gh api repos/<owner>/<repo>/actions/oidc/customization/sub` (`sub_claim_prefix`), and in **Trust relationships → Edit trust policy** set the condition to:

   ```json
   "StringEquals": {
     "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
     "token.actions.githubusercontent.com:sub": "repo:SoftwareEngAhmetDemir@43875085/vpc@1382315640:ref:refs/heads/main"
   }
   ```
4. Add the repo variables (Settings → Secrets and variables → Actions → Variables, or `gh variable set`). None are secrets:

   ```bash
   gh variable set AWS_REGION --body eu-north-1
   gh variable set AWS_ROLE_ARN --body arn:aws:iam::087134855638:role/github-deploy-role
   gh variable set BACKEND_INSTANCE_ID --body <backend-instance-id>
   gh variable set FRONTEND_INSTANCE_ID --body <frontend-instance-id>
   gh variable set BACKEND_PRIVATE_IP --body <backend-private-ip>
   ```

What a deploy does: the backend gets `git reset --hard <commit>`, `npm install`, `pm2 restart`, and a health check ([deploy/update-backend.sh](deploy/update-backend.sh)); it never touches `.env` or the database, so schema changes still need a manual `psql`. The frontend re-runs [deploy/frontend-deploy.sh](deploy/frontend-deploy.sh), which is safe to repeat. Watch runs in the repo's **Actions** tab; a failed deploy shows the instance's stdout/stderr in the log.

## 14. HTTPS with a free certificate (optional, recommended for phones)

Many phones and browsers block or rewrite plain `http://` to a bare IP. [deploy/frontend-deploy.sh](deploy/frontend-deploy.sh) can serve HTTPS with a free Let's Encrypt certificate. By default it uses the hostname `<ip-with-dashes>.sslip.io` (for example `13-63-170-46.sslip.io`), a free public DNS name that resolves to that IP, so no domain purchase is needed. It installs certbot, gets the certificate, redirects HTTP to HTTPS, and sets up automatic renewal (a systemd timer). If issuing the certificate fails, the site keeps working over HTTP and the deploy is marked failed.

Do this once in the Console:

1. **EC2 → Elastic IPs → Allocate Elastic IP address → Allocate.** Then select it → **Actions → Associate Elastic IP address** → resource type Instance → choose `frontend` → Associate. The instance's old auto-assigned public IP is released and replaced by this fixed one. Note the new IP. (Without this, the IP changes whenever the instance is stopped, and the certificate name would change with it.)
2. **EC2 → Security Groups → `frontend-sg` → Edit inbound rules → Add rule**: type **HTTPS**, source `0.0.0.0/0`. Save. Keep the HTTP (80) rule: it is needed for the certificate check and for the redirect.
3. Optional, own domain instead of sslip.io: create an `A` record pointing your domain at the Elastic IP, then `gh variable set DOMAIN --body app.example.com` (and optionally `gh variable set CERT_EMAIL --body you@example.com` for expiry notices).
4. Push to `main`, or run the workflow by hand from the Actions tab. The deploy prints `Frontend deployed: https://<name>/`.

The site is then at `https://<new-ip-with-dashes>.sslip.io/`. Opening `http://<ip>` redirects there. Certificates last 90 days and renew on their own.

Limits: certificates are per hostname, and Let's Encrypt caps how many it issues per week for a shared parent name like `sslip.io`. If issuing fails with a rate-limit message, use your own domain (step 3). An Elastic IP costs a small hourly fee like any public IPv4 address; release it during teardown.

## Notes / next steps

- This uses **EC2 + SSM** for the private backend to avoid needing a bastion host — simplest way to poke around a private subnet from the console.
- For anything beyond a demo, put an **Application Load Balancer** in the public subnets in front of the frontend (and optionally in front of the backend too, private-facing), rather than exposing EC2 instances directly — it gives you health checks, TLS termination, and easy horizontal scaling.
- Store `DB_PASSWORD` in **AWS Secrets Manager** instead of a plaintext `.env` once this becomes more than a demo.
- If you outgrow "click through the console," this whole setup (VPC, subnets, route tables, security groups, EC2, RDS) is a natural fit for Terraform or CloudFormation — ask if you want that version once you're comfortable with the manual steps.
