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
| `frontend-sg` | `sg-0b5d57261be03d187` | HTTP 80 and HTTPS 443 from `0.0.0.0/0` (443 added 2026-09-24, rule `sgr-09e874015c632263e`) |
| `backend-sg` | `sg-0fd97fc339130e522` | TCP 3001 from `frontend-sg` |
| `db-sg` | created third | PostgreSQL 5432 from `backend-sg` |

Sources are security group references, not CIDRs. Each SG needs a description (required field).

## 3. IAM

- Role `ec2-ssm-role`: trusted entity AWS service / EC2, policy `AmazonSSMManagedInstanceCore` (verified attached). Used as the instance profile on both EC2 instances so Session Manager works without SSH or a bastion.
- Identity provider (OIDC) `token.actions.githubusercontent.com`, audience `sts.amazonaws.com` (for GitHub Actions, see section 9).
- Policy `github-deploy-ssm` (customer managed): `ssm:SendCommand` on the two instance ARNs and `arn:aws:ssm:eu-north-1::document/AWS-RunShellScript`; `ssm:GetCommandInvocation` and `ssm:ListCommandInvocations` on `*`.
- Role `github-deploy-role` (`arn:aws:iam::087134855638:role/github-deploy-role`): web identity, only `github-deploy-ssm` attached. Trust policy: principal is the OIDC provider above, `aud` = `sts.amazonaws.com`, `sub` = `repo:SoftwareEngAhmetDemir@43875085/vpc@1382315640:ref:refs/heads/main`.

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
- `sudo dnf install -y git`, clone, then `bash frontend-deploy.sh` with `REPO_URL`, `BACKEND_PRIVATE_IP=10.0.11.246`: installed nginx, nodejs, git; built the React app; wrote `/etc/nginx/conf.d/vpc-demo.conf` proxying `/api/` to `http://10.0.11.246:3001/api/` (first design, replaced in section 8).
- Manual fix: AL2023's `/etc/nginx/nginx.conf` has its own default `server { server_name _; }` that beat our conf and returned 404 for `/api/items`. Removed it with `sudo sed -i '/^    server {$/,/^    }$/d' /etc/nginx/nginx.conf`, then `nginx -t` and reload. This edit exists only on this instance.

## 7. Result (first working state)

`http://13.63.170.46` showed "Hello World" and the 3 items: browser, frontend nginx :80, proxy `/api/*`, backend Express :3001 (private), RDS :5432 (private). Backend and RDS have no public IP and no inbound route from the internet; the only public entry point is the frontend's port 80. The private subnets reach the internet outbound only, through the NAT gateway. Downside found: `/api/items` was readable by anyone through the nginx proxy, because the browser itself had to call it.

## 8. Design history: private API vs browser-called API

First design (section 7): nginx served the React build and proxied `/api/*` to the backend, so the browser called `/api/items`. Concern raised: that URL is readable by anyone. Second design: `frontend/server.js` (Node, pm2) fetched the data server-side and embedded it in the HTML, with `/api/*` returning 404. That was deployed and verified (API 404 from the internet, page 200 with items embedded).
Current decision (chosen by the user): the browser calls the API itself, like a normal SPA. Reverted to nginx static files plus `/api/` proxy: `frontend/server.js` and the `express` dependency were removed, `frontend/.env.production` (`VITE_API_URL=` empty, so same-origin) was restored, `App.jsx` fetches `/api/items` again, `nginx.conf.example` has the `/api/` proxy again. `deploy/frontend-deploy.sh` builds, copies `dist` to `/var/www/vpc-demo`, deletes the old pm2 `frontend` process, removes the AL2023 default nginx server block, writes the proxy conf, and curls `/` and `/api/items` as a health check. The CI step no longer runs `node --check` on a frontend server. Nothing in AWS changes: the backend and RDS are still private, and only nginx on the frontend can reach the backend. `/api/items` is public again by design; restricting it to logged-in users would need auth on the backend.
Other deploy script fixes: use `$HOME/app`, the IMDSv2 token for the IP lookup. New helpers: `deploy/update-backend.sh` (npm install, pm2 restart, health check), `deploy/ssm-run.sh` (SSM Run Command wrapper).
The revert is committed only after a push to `main`; that push deploys it through the pipeline.

## 9. CI/CD with GitHub Actions (DONE and working)

`.github/workflows/deploy.yml`: CI (install, build, `node --check`, `bash -n`) on every push and PR. CD on pushes to `main` after CI passes: assumes `github-deploy-role` via OIDC (no stored keys), then runs through SSM Run Command as `ssm-user`: `deploy/update-backend.sh` on the backend, `deploy/frontend-deploy.sh` on the frontend, both after `git reset --hard <commit>` in `~/app`. The deploy job is skipped if repo variable `AWS_ROLE_ARN` is unset.
GitHub repo variables (set with `gh variable set`, none secret): `AWS_REGION=eu-north-1`, `AWS_ROLE_ARN`, `BACKEND_INSTANCE_ID`, `FRONTEND_INSTANCE_ID`, `BACKEND_PRIVATE_IP=10.0.11.246`.
Problem hit: the first deploy failed with "Not authorized to perform sts:AssumeRoleWithWebIdentity" although the trust policy looked right. This repo uses immutable OIDC subjects (`gh api repos/SoftwareEngAhmetDemir/vpc/actions/oidc/customization/sub` shows the prefix), so the token `sub` contains owner and repo IDs. Fixed by editing the trust policy `sub` to the ID form (section 3).
First successful run (re-run of run 35928625323): CI 11s, deploy 49s. Verified afterwards from outside (server-side fetch design at that time): `/api/items` 404, `/` 200 with items embedded, backend private IP unreachable.
Not automated: `schema.sql` (run `psql` by hand from the backend), `backend/.env` edits, any AWS infrastructure change.

## 9b. HTTPS

Why: the site only worked on the laptop; phones block or rewrite plain `http://` to a bare IP, and the server had no HTTPS. (Earlier "reachable" curl tests ran on the user's own laptop, so they proved nothing about other networks; the AWS side was already fully public.)
Step 1 (live, verified): the pipeline deploy (commit `0518af9`) issued a Let's Encrypt certificate for `13-63-170-46.sslip.io` (expires 2026-12-23) and nginx redirected `http://13.63.170.46/` to `https://13-63-170-46.sslip.io/`. It ran BEFORE port 443 was open, so for a while the redirect landed on a timeout; fixed by adding HTTPS 443 from `0.0.0.0/0` to `frontend-sg` (open 443 before deploying). Verified from outside afterwards: 200, valid certificate, `/api/items` over HTTPS, backend private IP unreachable.
Step 2 (code written, NOT deployed yet): the user did not want the redirect to a hostname and asked for `https://13.63.170.46` directly. `deploy/frontend-deploy.sh` now defaults to a Let's Encrypt IP-address certificate (research: GA since 2026-01-15, `shortlived` profile, ~6 days, HTTP-01, certbot >= 5.3.0 with `--ip-address`, which works only with the standalone/manual plugin). It builds `/opt/certbot` from Python 3.12/3.11 if certbot is older than 5.3.0, issues `certbot certonly --standalone --ip-address <ip> --preferred-profile shortlived --cert-name ip-<ip>` with `--pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx"`, renders `frontend/nginx-ip.conf.example` (80 and 443 both serve the site, NO redirect), deletes older certs (the sslip.io one), runs `certbot renew --dry-run`, and installs `certbot-renew.timer` (twice daily; each renewal briefly stops nginx). `DOMAIN` repo variable set => domain mode instead (`nginx-ssl.conf.example`, webroot, redirect to `https://<domain>`). If issuing fails, the existing nginx config keeps running and the deploy exits non-zero. All three nginx templates pass `nginx -t` locally; the real IP-certificate issuance and renewal have NOT been run yet.
Still to do: allocate an Elastic IP and associate it with `frontend` (`DEPLOY_AWS.md` section 14). Until then the certificate is tied to the auto-assigned IP `13.63.170.46`; if the instance is stopped and started the IP changes, and the next deploy issues a new certificate.

## 10. Open items

- The GitHub repo is public (needed so the instances can `git clone` without credentials). The role trust policy only allows `main` of this repo, so forks and PRs cannot deploy.
- The RDS master password was typed into a chat and shell history. Rotate it or move it to Secrets Manager beyond a demo.
- The frontend public IP `13.63.170.46` is auto-assigned, not an Elastic IP, and changes if the instance is stopped and started; the IP certificate depends on it (see 9b).
- Billing while running: NAT gateway (hourly + data), RDS `db.t4g.micro`, two t3.micro. Teardown order: EC2 instances, RDS (skip final snapshot), NAT gateway, release its Elastic IP, then route tables, subnets, IGW, VPC (see `DEPLOY_AWS.md` step 12). For the pipeline, also delete `github-deploy-role`, `github-deploy-ssm` and the OIDC provider if unused.
