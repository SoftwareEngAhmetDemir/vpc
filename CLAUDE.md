# AWS changes log (vpc-demo)

Everything created or changed in AWS for this project, in the order it was done. All in the Console, account `087134855638`, region **eu-north-1 (Stockholm)**, so AZs are `eu-north-1a` / `eu-north-1b`. App code and repo details are in `README.md` and `DEPLOY_AWS.md`.

## 1. Network (VPC service)

1. VPC `vpc-demo`, IPv4 `10.0.0.0/16` (`vpc-0d48aa73f7f0a343e`), "VPC only", no IPv6, default tenancy, no encryption control.
2. Four subnets in `vpc-demo`:
   - `public-a` `10.0.1.0/24`, eu-north-1a (`subnet-09e84df2e91cf8034`)
   - `public-b` `10.0.2.0/24`, eu-north-1b
   - `private-a` `10.0.11.0/24`, eu-north-1a (`subnet-0b4c87553875fcac7`)
   - `private-b` `10.0.12.0/24`, eu-north-1b (`subnet-05bb3db1d593454cc`)
3. Edit subnet settings: enabled "Auto-assign public IPv4 address" on `public-a` and `public-b` only (done one at a time; bulk edit is greyed out).
4. Internet gateway `vpc-demo-igw` (`igw-04a6df23064bad86d`), attached to `vpc-demo`.
5. Route table `public-rt`: `10.0.0.0/16` local, `0.0.0.0/0` to `vpc-demo-igw`. Associated with `public-a`, `public-b`.
6. NAT gateway `vpc-demo-nat` (`nat-053905fbf5bc7eac8`): zonal (not the new Regional option), subnet `public-a`, connectivity Public, new Elastic IP auto-allocated.
7. Route table `private-rt` (`rtb-078e158fdb4b46ee2`): `10.0.0.0/16` local, `0.0.0.0/0` to `vpc-demo-nat`. Associated with `private-a`, `private-b`.

## 2. Security groups (all in `vpc-demo`, outbound left as default all-traffic)

| Name | ID | Inbound |
|---|---|---|
| `frontend-sg` | `sg-0b5d57261be03d187` | HTTP 80 from `0.0.0.0/0` |
| `backend-sg` | `sg-0fd97fc339130e522` | TCP 3001 from `frontend-sg` |
| `db-sg` | created third | PostgreSQL 5432 from `backend-sg` |

Sources are security group references, not CIDRs. Each SG needs a description (required field).

## 3. IAM

- Role `ec2-ssm-role`: trusted entity AWS service / EC2, policy `AmazonSSMManagedInstanceCore` (verified attached). Used as the instance profile on both EC2 instances so Session Manager works without SSH or a bastion.

## 4. RDS

1. DB subnet group `vpc-demo-db-subnets`: VPC `vpc-demo`, AZs 1a and 1b, subnets `private-a` and `private-b`.
2. Database `vpc-demo-db`:
   - Full configuration, engine **PostgreSQL** (not Aurora), template **Free tier**, PostgreSQL 18.3, Single-AZ
   - Instance `db.t4g.micro`, storage default, encryption on (default `aws/rds` key)
   - Master user `postgres`, self-managed password (not recorded here)
   - VPC `vpc-demo`, subnet group `vpc-demo-db-subnets`, **Public access: No**, security group `db-sg` only, AZ eu-north-1a
   - Initial database name `vpcdemo`; RDS Proxy off; backups 1 day (defaults); deletion protection left at default
   - Endpoint: `vpc-demo-db.ch4uigieg080.eu-north-1.rds.amazonaws.com`

## 5. EC2

| | backend | frontend |
|---|---|---|
| Instance ID | `i-02f210779846a935a` | `i-0e47fc73fb1e4c74b` |
| AMI / type | Amazon Linux 2023 (kernel 6.18), t3.micro | same |
| Key pair | none (SSM only) | none (SSM only) |
| Subnet | `private-a` | `public-a` |
| Public IP | none | auto-assigned `13.63.170.46` (not an Elastic IP; changes on stop/start) |
| Private IP | `10.0.11.246` | `10.0.1.5` |
| Security group | `backend-sg` | `frontend-sg` |
| IAM instance profile | `ec2-ssm-role` | `ec2-ssm-role` |

Correction made after launch: the backend was first created with the wizard's auto-created `launch-wizard-1` SG (SSH open to `0.0.0.0/0`). Fixed via Instances, Actions, Security, Change security groups, replaced with `backend-sg` only, and verified. Always check the SG in the launch form.

## 6. Changes made on the instances (via SSM Session Manager)

Backend (`ssm-user`, run from `~/app/deploy`):
- `git clone https://github.com/SoftwareEngAhmetDemir/vpc.git app` (needed `sudo dnf install -y git` first, and `cd ~` because the SSM shell starts in a non-writable dir).
- `bash backend-deploy.sh` with `REPO_URL`, `RDS_ENDPOINT`, `DB_PASSWORD`: installed nodejs, git, postgresql16, `npm install`, wrote `backend/.env` (`DB_SSL=true`), loaded `schema.sql` into RDS (3 seed rows), installed pm2 globally, started `backend` under pm2, enabled `pm2-ssm-user` systemd unit, `pm2 save`.
- Verified: `curl localhost:3001/api/health` returns ok, `/api/items` returns the 3 rows.

Frontend:
- `sudo dnf install -y git`, clone, then `bash frontend-deploy.sh` with `REPO_URL`, `BACKEND_PRIVATE_IP=10.0.11.246`: installed nginx, nodejs, git; built the React app (`VITE_API_URL` empty) into `/var/www/vpc-demo/dist`; wrote `/etc/nginx/conf.d/vpc-demo.conf` proxying `/api/` to `http://10.0.11.246:3001/api/`.
- Manual fix: AL2023's `/etc/nginx/nginx.conf` has its own default `server { server_name _; }` that beat our conf and returned 404 for `/api/items`. Removed it with `sudo sed -i '/^    server {$/,/^    }$/d' /etc/nginx/nginx.conf`, then `nginx -t` and reload. This edit exists only on this instance.

## 7. Result

`http://13.63.170.46` shows "Hello World" and the 3 items. Deployed state (before section 8): browser, frontend nginx :80, proxy `/api/*`, backend Express :3001 (private), RDS :5432 (private). Backend and RDS have no public IP and no inbound route from the internet; the only public entry point is the frontend's port 80. The private subnets reach the internet outbound only, through the NAT gateway.

## 8. Change: hide the API from the browser (code done, NOT yet deployed to the frontend instance)

Problem: with nginx proxying `/api/*`, `http://13.63.170.46/api/items` was readable by anyone, because the browser had to call it.
New design: `frontend/server.js` (Express, port 3000, run by pm2) fetches `http://10.0.11.246:3001/api/items` server-side, injects the result into `index.html` as `window.__INITIAL_STATE__`, and returns 404 on `/api/*`. nginx forwards port 80 to `127.0.0.1:3000` and has no `/api` location. Nothing in AWS (SGs, subnets, routes) changes.
To apply on the frontend instance (SSM): `cd ~/app && git pull && cd deploy && BACKEND_PRIVATE_IP=10.0.11.246 REPO_URL=https://github.com/SoftwareEngAhmetDemir/vpc.git bash frontend-deploy.sh`. The old `~/app/deploy/app` clone from the first run is unused and can be deleted.
Both deploy scripts now also use `$HOME/app`, the IMDSv2 token for the IP lookup, and the frontend script removes the AL2023 default nginx server block itself.

## 9. Planned: CI/CD pipeline (code written, AWS side NOT done yet)

`.github/workflows/deploy.yml`: CI (build, syntax checks) on every push/PR; CD on `main` only, deploying via SSM Run Command (`deploy/ssm-run.sh`) as `ssm-user`: `deploy/update-backend.sh` on the backend, `deploy/frontend-deploy.sh` on the frontend. Deploy job is skipped while repo variable `AWS_ROLE_ARN` is unset.
AWS changes still to make (steps in `DEPLOY_AWS.md` section 13): IAM OIDC provider `token.actions.githubusercontent.com`; IAM policy `github-deploy-ssm` (SendCommand on the two instances + `AWS-RunShellScript`, GetCommandInvocation); IAM role `github-deploy-role` trusted only for `repo:SoftwareEngAhmetDemir/vpc:ref:refs/heads/main`. GitHub repo variables: `AWS_REGION`, `AWS_ROLE_ARN`, `BACKEND_INSTANCE_ID`, `FRONTEND_INSTANCE_ID`, `BACKEND_PRIVATE_IP`.
The first pipeline run also performs the section 8 migration on the frontend instance.

## 10. Open items

- The code changes in sections 8 and 9 are not committed or pushed yet.
- The GitHub repo was switched to public so instances can clone without credentials.
- The RDS master password was typed into a chat and shell history. Rotate it or move it to Secrets Manager beyond a demo.
- Billing while running: NAT gateway (hourly + data), RDS `db.t4g.micro`, two t3.micro. Teardown order: EC2 instances, RDS (skip final snapshot), NAT gateway, release its Elastic IP, then route tables, subnets, IGW, VPC (see `DEPLOY_AWS.md` step 12).
