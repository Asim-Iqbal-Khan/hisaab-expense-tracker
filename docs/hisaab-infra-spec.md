# Hisaab — Infrastructure & Architecture Specification

**Version:** 0.2
**Region:** us-west-2 (Oregon)
**Environments:** production only
**Companion to:** `hisaab-prd.md` (features), `hisaab-schema.sql` (database)
**Last updated:** 27 July 2026

This document specifies every deployed component, where it sits, and how it connects. It is written to be drawn from — §13 lists the diagram layers explicitly.

**Changes from v0.1:** NAT gateway switched to regional availability mode; RDS switched to Multi-AZ; DNS and certificate handling added (§3.6, §3.7); scope reduced to a single production environment.

---

## 1. Architecture summary

A three-tier VPC across two availability zones. An internet-facing ALB in public subnets terminates TLS and forwards to a dockerised API running on EC2 in private application subnets, managed by autoscaling groups. Postgres on RDS runs Multi-AZ in isolated private data subnets with no route to the internet. Cognito handles identity, S3 and CloudFront serve static assets and user uploads, SNS delivers notifications, and deployments run blue/green through CodePipeline and CodeDeploy.

**Deployment model:** blue/green. Two autoscaling groups, each spanning both AZs, each fronted by its own target group. The ALB listener points at one at a time.

**Availability posture:** the app tier, NAT egress, and the database can each survive the loss of one availability zone. This is a deliberate, coherent choice — see decisions D2 and D11.

---

## 2. Region and availability zones

| Property | Value |
|---|---|
| Region | us-west-2 |
| AZ A | us-west-2a |
| AZ B | us-west-2b |

Every tier is present in both AZs. AZ choice is pinned by AZ ID, not name, so the mapping stays stable across accounts.

---

## 3. Network, DNS and certificates

### 3.1 VPC

| Property | Value |
|---|---|
| CIDR | 10.0.0.0/16 |
| DNS hostnames | enabled |
| DNS support | enabled |
| Tenancy | default |
| Flow logs | enabled, to CloudWatch Logs, REJECT traffic only |

### 3.2 Subnets

| Name | CIDR | AZ | Tier | Public IP on launch | Route table |
|---|---|---|---|---|---|
| `sn-public-a` | 10.0.0.0/24 | us-west-2a | Public | yes | `rt-public` |
| `sn-public-b` | 10.0.1.0/24 | us-west-2b | Public | yes | `rt-public` |
| `sn-app-a` | 10.0.16.0/20 | us-west-2a | Private app | no | `rt-app` |
| `sn-app-b` | 10.0.32.0/20 | us-west-2b | Private app | no | `rt-app` |
| `sn-data-a` | 10.0.48.0/24 | us-west-2a | Private data | no | `rt-data` |
| `sn-data-b` | 10.0.49.0/24 | us-west-2b | Private data | no | `rt-data` |

Public and data subnets are `/24`; they hold a handful of ENIs each and never need more. Application subnets are `/20` because that is the only tier that scales horizontally. Remaining space is reserved.

### 3.3 Gateways

| Component | Placement | Notes |
|---|---|---|
| `igw-hisaab` | VPC-attached | Ingress and egress for public subnets; also required by the regional NAT |
| `nat-hisaab` | **VPC-level, not subnet-scoped** | Regional availability mode |

**The NAT gateway does not live in a subnet.** Regional availability mode creates one VPC-scoped gateway that automatically expands into an AZ when workloads appear there and contracts when they leave. This is a real difference from a zonal NAT gateway and it changes how you draw the diagram — do not place it inside `sn-public-a`.

Consequences worth knowing:

- Billing is **per active AZ**, so with the app tier in both zones this costs the same as two zonal gateways (~$66/month). Regional mode buys operational simplicity and automatic failover, not savings.
- Expansion into a newly active AZ takes roughly 15–20 minutes. It is not instant.
- Expansion is triggered by ENI presence, and **public-subnet resources trigger it too**. The ALB nodes alone keep the gateway active in both AZs regardless of where EC2 instances sit.
- An Elastic IP is consumed per active AZ.
- Regional mode does not support centralised egress patterns via Transit Gateway. Not relevant here.

### 3.4 Route tables

| Route table | Associated subnets | Routes |
|---|---|---|
| `rt-public` | `sn-public-a`, `sn-public-b` | `10.0.0.0/16` → local<br>`0.0.0.0/0` → `igw-hisaab` |
| `rt-app` | `sn-app-a`, `sn-app-b` | `10.0.0.0/16` → local<br>`0.0.0.0/0` → `nat-hisaab`<br>S3 prefix list → `vpce-s3` |
| `rt-data` | `sn-data-a`, `sn-data-b` | `10.0.0.0/16` → local |

**One shared application route table**, not one per AZ. This is the operational payoff of regional mode: with zonal NAT gateways you would need `rt-app-a` and `rt-app-b` pointing at different gateway IDs, plus a duplicate S3 endpoint association. Here every private subnet routes to the same gateway ID.

`rt-data` deliberately has **no default route**. The database tier cannot reach the internet in either direction. RDS backups, monitoring, and Performance Insights are handled by the RDS service outside your route tables and do not need one.

### 3.5 VPC endpoints

| Endpoint | Type | Attached to | Cost |
|---|---|---|---|
| `vpce-s3` | Gateway (S3) | `rt-app` | Free |

Profile picture traffic between EC2 and S3 never crosses the NAT gateway, avoiding both the per-GB processing charge and the data transfer charge. Interface endpoints for ECR, Secrets Manager, and CloudWatch Logs were considered and rejected — at roughly $7/month per endpoint per AZ, replacing the NAT with endpoints would cost more than the NAT itself.

### 3.6 DNS and domain delegation

**Domain:** the app is not on its own domain — it lives under an existing subdomain of a shared organisational domain.

| Property | Value |
|---|---|
| Root domain | `cloudelligent-sandbox.com` |
| Existing hosted zone | `example.com` |
| Hosted zone ID | `Z06937211L1EVF6QE14XW` |
| Project subdomain | `hisaab.example.com` |

This zone already exists and is already delegated — it was purchased through Route 53, so there is no registrar nameserver step. Terraform does **not** create a new hosted zone. It writes records into the existing zone by referencing the zone ID above, using a `data "aws_route53_zone"` lookup or the ID directly as a variable — never a hardcoded zone creation.

Every application record lives under the `hisaab.` prefix, so nothing this project creates can collide with whatever else runs on `example.com`.

| Record | Type | Target |
|---|---|---|
| `hisaab.example.com` | A (alias) | CloudFront distribution |
| `app.hisaab.example.com` | A (alias) | `alb-hisaab` |
| ACM validation records | CNAME | Created automatically by Terraform, scoped under `hisaab.` |

There is no `www.` record — a three-level subdomain doesn't need one.

**ACM certificates are created by Terraform, never by hand.** Terraform generates the certificate, writes its DNS validation record into the existing zone, and waits on `aws_acm_certificate_validation`. This keeps the certificate's lifecycle — including renewal — tracked in state rather than existing as an out-of-band console object nothing else knows about.

Hosted zone cost is already being paid by whoever owns the parent zone; this project adds no new zone cost. Queries resolved to AWS alias targets are not charged.

### 3.7 ACM certificates

**Two certificates are required.** Certificates are regional and cannot be copied between regions.

| Certificate | Region | Covers | Attached to |
|---|---|---|---|
| `cert-alb` | **us-west-2** | `app.hisaab.example.com` | ALB HTTPS listener |
| `cert-cloudfront` | **us-east-1** | `hisaab.example.com` | CloudFront distribution |

CloudFront reads certificates only from us-east-1, regardless of where the rest of the infrastructure lives. This requires a second AWS provider alias in Terraform:

```hcl
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
```

Both certificates use DNS validation, which means they renew automatically for as long as the Route 53 records exist. Email validation does not auto-renew and must not be used.

**Split-origin consequence:** the frontend is served from `hisaab.example.com` and the API from `app.hisaab.example.com`. These are different origins, so the API must send correct CORS headers (`Access-Control-Allow-Origin`, credential handling, preflight responses) or every browser request fails. This is an application concern caused by an infrastructure decision, so it is recorded here.

---

## 4. Component inventory

Everything deployed, and where it lives. This is the source table for the diagram.

| Component | Service | Placement | Public |
|---|---|---|---|
| `cf-hisaab` | CloudFront | Edge (global) | Yes |
| `alb-hisaab` | ELBv2 | `sn-public-a`, `sn-public-b` | Yes |
| `nat-hisaab` | NAT Gateway (regional) | VPC-level, active in both AZs | Yes (EIP per AZ) |
| `asg-hisaab-blue` | EC2 Auto Scaling | `sn-app-a`, `sn-app-b` | No |
| `asg-hisaab-green` | EC2 Auto Scaling | `sn-app-a`, `sn-app-b` | No |
| `tg-hisaab-blue` | Target group | VPC | — |
| `tg-hisaab-green` | Target group | VPC | — |
| `rds-hisaab` | RDS Postgres, Multi-AZ | `sn-data-a` + `sn-data-b` | No |
| `fn-post-confirmation` | Lambda | `sn-app-a`, `sn-app-b` | No |
| `fn-reminder-dispatcher` | Lambda | `sn-app-a`, `sn-app-b` | No |
| `hisaab-user-pool` | Cognito | Regional (outside VPC) | Yes |
| `hisaab-notifications` | SNS topic | Regional | — |
| `sched-weekly-reminder` | EventBridge Scheduler | Regional | — |
| `hisaab-api` | ECR repository | Regional | No |
| Route 53 hosted zone | Route 53 | Global | Yes |
| S3 buckets (§8) | S3 | Regional | No |
| CodePipeline / CodeBuild / CodeDeploy | Regional | — | — |

---

## 5. Security groups

Every rule references another security group by ID, never a CIDR, except where internet ingress is genuinely required.

| Security group | Attached to | Inbound | Outbound |
|---|---|---|---|
| `sg-alb` | ALB | 443/tcp from `0.0.0.0/0`<br>80/tcp from `0.0.0.0/0` | 8080/tcp to `sg-app` |
| `sg-app` | EC2 instances | 8080/tcp from `sg-alb` | 443/tcp to `0.0.0.0/0`<br>5432/tcp to `sg-data` |
| `sg-data` | RDS | 5432/tcp from `sg-app`<br>5432/tcp from `sg-lambda` | none |
| `sg-lambda` | Both Lambdas | none | 443/tcp to `0.0.0.0/0`<br>5432/tcp to `sg-data` |

**No SSH anywhere.** Port 22 is never opened. Shell access is via SSM Session Manager, which reaches instances outbound through the NAT and requires no inbound rule and no key pair.

Port 80 on the ALB exists solely to serve a 301 redirect to 443. It never forwards to a target group.

**The ALB accepts traffic from anywhere, not only CloudFront.** CloudFront fronts the static frontend only; the browser calls the API at `app.hisaab.example.com` directly. If the API is ever moved behind CloudFront, `sg-alb` should be narrowed to the `com.amazonaws.global.cloudfront.origin-facing` managed prefix list.

---

## 6. Compute layer

### 6.1 Launch template `lt-hisaab-api`

| Property | Value |
|---|---|
| AMI | Amazon Linux 2023, ARM64 |
| Instance type | t4g.small |
| IMDS | v2 required, hop limit 1 |
| Root volume | 20 GB gp3, encrypted |
| Instance profile | `role-ec2-hisaab` |
| Security group | `sg-app` |
| Detailed monitoring | enabled |

User data, in order: install and start Docker, install the CodeDeploy agent, authenticate to ECR, pull the image tag baked into this launch template version, fetch the DB secret from Secrets Manager, start the container on port 8080.

**The image tag is pinned per launch template version.** Never `latest`. The tag is the git commit SHA, which is what makes rollback possible — reverting a deploy is reverting to the previous launch template version.

### 6.2 Autoscaling groups

Two identical groups, `blue` and `green`. Only one is live at a time; the other exists transiently during deployment.

| Property | Value |
|---|---|
| Subnets | `sn-app-a`, `sn-app-b` |
| Min / desired / max | 2 / 2 / 4 |
| Health check type | **ELB** (not EC2) |
| Health check grace period | 180s |
| Scaling policy | Target tracking, `ALBRequestCountPerTarget` = 1000 |
| Termination policy | Default, balanced across AZs |

`min_size = 2` with two AZs guarantees one instance per zone. Health check type must be ELB — with EC2 checks, a container that has crashed inside a running instance is never replaced.

### 6.3 Application load balancer

| Property | Value |
|---|---|
| Scheme | internet-facing |
| Subnets | `sn-public-a`, `sn-public-b` |
| Listener 443 | HTTPS, `cert-alb` (us-west-2), forward to live target group |
| Listener 80 | HTTP, 301 redirect to 443 |
| Access logs | `s3://hisaab-alb-logs-prod/` |
| Idle timeout | 60s |
| Deletion protection | enabled |

Target groups `tg-hisaab-blue` and `tg-hisaab-green`, both port 8080/HTTP:

| Property | Value |
|---|---|
| Health check path | `/health` |
| Healthy / unhealthy threshold | 2 / 3 |
| Interval / timeout | 15s / 5s |
| Deregistration delay | 30s |

The `/health` endpoint must verify database connectivity, not just that the process is alive. A container that starts but cannot reach RDS would otherwise pass health checks and get promoted to live during a blue/green cutover.

---

## 7. Data layer

| Property | Value |
|---|---|
| Engine | PostgreSQL 16 |
| Instance class | db.t4g.micro |
| Storage | 20 GB gp3, autoscaling to 100 GB |
| **Multi-AZ** | **Yes** |
| Subnet group | `sn-data-a`, `sn-data-b` |
| Security group | `sg-data` |
| Publicly accessible | No |
| Encryption at rest | Yes, AWS-managed KMS key |
| Backup retention | 7 days |
| Backup window | 09:00–10:00 UTC |
| Maintenance window | Tue 10:00–11:00 UTC |
| Deletion protection | enabled |
| Performance Insights | enabled, 7-day retention (free tier) |
| Enhanced monitoring | 60s interval |

### 7.1 What Multi-AZ actually does

RDS maintains a **synchronous standby replica** in the other data subnet. Four things follow, and they are commonly misunderstood:

- **The standby is not readable.** It serves zero queries. It is not a read replica and cannot offload reads. You are paying for an idle instance, and that is the entire point.
- **Failover is automatic and takes roughly 60–120 seconds.** RDS repoints the DNS of the same endpoint at the standby. The application's connection string never changes.
- **Which AZ holds the primary is not fixed.** After a failover the primary is in `sn-data-b` and stays there. Never diagram or assume a permanent primary AZ.
- **Patching downtime drops sharply.** RDS patches the standby, fails over to it, then patches the old primary.

Backups are taken from the standby, so there is no I/O suspension on the primary during the backup window.

**The application must cooperate with failover.** A connection pool holding open sockets to the old primary keeps handing out dead connections after the DNS swings. Configure the pool to validate connections before use and retry on connection failure, or a 90-second RDS failover becomes a much longer application outage.

Cost is roughly double a single-AZ instance: two instances and two copies of storage.

### 7.2 Credentials

The master password is generated by Secrets Manager with RDS-managed rotation every 30 days. It never appears in Terraform variables, user data, or the AMI. The EC2 instance role can read exactly one secret ARN.

### 7.3 Schema migrations

`hisaab-schema.sql` is **not** applied by Terraform. Provisioning the database and running DDL against it are separate concerns; a `null_resource` with a `psql` provisioner breaks Terraform's state model and causes problems on every subsequent plan. Migration tooling is an open item (§17).

The schema requires the `citext` extension, which ships with RDS Postgres and needs `CREATE EXTENSION citext;` run once as part of the first migration — not a parameter group change.

---

## 8. Storage

| Bucket | Purpose | Public access | Notes |
|---|---|---|---|
| `hisaab-profile-pics-prod` | User avatars | Blocked (all four settings) | Accessed only via pre-signed URLs |
| `hisaab-frontend-prod` | Static SPA assets | Blocked | Served via CloudFront with OAC |
| `hisaab-alb-logs-prod` | ALB access logs | Blocked | Lifecycle: expire at 90 days |
| `hisaab-pipeline-artifacts-prod` | CodePipeline artifacts | Blocked | Lifecycle: expire at 30 days |
| `hisaab-tfstate` | Terraform state | Blocked | Versioning on, created by bootstrap |

All buckets: SSE-S3 encryption minimum, versioning enabled on state and profile pictures, and a bucket policy denying any request where `aws:SecureTransport` is false.

**Frontend delivery.** `hisaab-frontend-prod` is private. CloudFront reaches it through an Origin Access Control, so the bucket is never publicly readable and there is no S3 website endpoint. CloudFront serves `hisaab.example.com` using `cert-cloudfront`.

**Profile picture flow.** The browser never receives AWS credentials. It requests an upload URL from the API, which returns a pre-signed PUT valid for 5 minutes, constrained to a specific key, content type, and 5 MB size limit. Reads use pre-signed GET URLs with a 1 hour expiry. CORS on this bucket allows `PUT` from the app origin only.

---

## 9. Identity

### 9.1 Cognito user pool `hisaab-user-pool`

| Property | Value |
|---|---|
| Sign-in aliases | `email`, `preferred_username` |
| Required attributes | `email`, `preferred_username` |
| MFA | optional (TOTP) |
| Password policy | 8+ chars, upper, lower, number |
| Email verification | required, Cognito default sender |
| Account recovery | verified email only |
| Lambda trigger | Post Confirmation → `fn-post-confirmation` |

`preferred_username` is used deliberately: Cognito enforces uniqueness on it within the pool, which gives the unique-username guarantee the product spec requires without a second uniqueness mechanism. The RDS `users.username` column mirrors it.

### 9.2 App client

| Property | Value |
|---|---|
| Client type | Public (SPA), no client secret |
| Auth flow | Authorization code + PKCE |
| Callback URL | `https://hisaab.example.com/callback` |
| Sign-out URL | `https://hisaab.example.com` |
| Access token validity | 1 hour |
| Refresh token validity | 30 days |

**Hosted UI domain:** Cognito prefix domain (`hisaab.auth.us-west-2.amazoncognito.com`). This ships with valid HTTPS at no cost. A custom auth domain such as `auth.hisaab.example.com` would require a *third* ACM certificate in us-east-1, because Cognito custom domains are CloudFront-backed. Out of scope for v1.

### 9.3 Token validation

The API validates JWTs locally against the pool's JWKS, cached in memory with a 12 hour TTL. No per-request call to Cognito.

---

## 10. Notifications

### 10.1 Topology

A single SNS topic, `hisaab-notifications`, with one email subscription per user. Each subscription carries a **filter policy** on the `user_id` message attribute, so a message published with `user_id = X` reaches only X's subscription.

```
publish { user_id: "abc-123", type: "expense_added" }
   → SNS evaluates filter policies
   → delivers only to the subscription whose policy matches abc-123
```

The subscription is created by `fn-post-confirmation` at signup and its ARN is stored in `user_notification_prefs.sns_subscription_arn`. AWS sends a one-time confirmation email; until the user clicks it, the subscription is pending and receives nothing. The API surfaces this state via `sns_confirmed_at` so users understand why they aren't receiving notifications.

### 10.2 Event-driven publishes

Published synchronously by the API on: group invitation received, expense added involving you, settlement recorded with you.

### 10.3 Scheduled reminders

```
EventBridge Scheduler (weekly cron)
   → fn-reminder-dispatcher (in VPC, sg-lambda)
   → query v_net_balances for users with a negative net position
   → filter out anyone with last_reminded_at within 7 days
   → publish one aggregated message per user to SNS
```

One message per user summarising all groups — never one per group.

---

## 11. IAM roles

| Role | Attached to | Permissions |
|---|---|---|
| `role-ec2-hisaab` | EC2 instance profile | `ecr:GetAuthorizationToken`, `ecr:BatchGetImage` on `hisaab-api`; `secretsmanager:GetSecretValue` on the DB secret ARN; `s3:GetObject`/`PutObject`/`DeleteObject` on `hisaab-profile-pics-prod/*`; `sns:Publish` on the topic ARN; `logs:*` on its own log group; `AmazonSSMManagedInstanceCore` |
| `role-lambda-postconfirm` | `fn-post-confirmation` | VPC ENI management; DB secret read; `sns:Subscribe` on the topic; own log group |
| `role-lambda-reminder` | `fn-reminder-dispatcher` | VPC ENI management; DB secret read; `sns:Publish`; own log group |
| `role-codebuild` | CodeBuild project | ECR push to `hisaab-api`; artifact bucket RW; own log group |
| `role-codedeploy` | CodeDeploy | `AWSCodeDeployRole` — manages ASGs, target groups, terminates instances |
| `role-codepipeline` | CodePipeline | Invoke CodeBuild and CodeDeploy; artifact bucket RW; source connection |
| `role-terraform` | Infra pipeline | Broad, but scoped to the account and denied on IAM user/root operations |

Every S3, Secrets Manager, and SNS permission names a specific ARN. No wildcards on resources.

---

## 12. CI/CD

Two separate pipelines. Infrastructure changes are slow and reviewed; application changes are fast and frequent. Coupling them means every code deploy runs a Terraform plan against your database.

### 12.1 Application pipeline `pipe-hisaab-app`

| Stage | Action | Detail |
|---|---|---|
| Source | CodeStar connection | GitHub, `main` branch |
| Build | CodeBuild | `docker build`, tag = commit SHA, push to ECR, emit appspec artifact |
| Deploy | CodeDeploy | Blue/green to the ASG |

CodeDeploy deployment group config:

```
deployment_style           BLUE_GREEN / WITH_TRAFFIC_CONTROL
green_fleet_provisioning   COPY_AUTO_SCALING_GROUP
deployment_ready_option    CONTINUE_DEPLOYMENT
terminate_blue_instances   TERMINATE, wait 10 minutes
auto_rollback              DEPLOYMENT_FAILURE, DEPLOYMENT_STOP_ON_ALARM
alarm                      alb-5xx-high
```

Sequence: copy the ASG using the new launch template version → wait for green instances to pass target group health checks → swap the listener's default action to the green target group → wait 10 minutes → terminate blue instances.

The 10-minute window is the rollback budget. During it, the previous fleet is still running and warm.

**Terraform gotcha:** the ALB listener needs `lifecycle { ignore_changes = [default_action] }`. CodeDeploy mutates the listener on every deploy, and without this the next `terraform apply` reverts production traffic to the old target group.

### 12.2 Infrastructure pipeline `pipe-hisaab-infra`

| Stage | Action |
|---|---|
| Source | GitHub, `main`, `infra/**` path filter |
| Validate | `terraform fmt -check`, `validate`, `tflint`, `checkov` |
| Plan | `terraform plan -out=tfplan`, plan saved as artifact |
| Approve | Manual approval gate |
| Apply | `terraform apply tfplan` |

The manual gate exists because the same plan that adds a security group rule can also destroy an RDS instance.

### 12.3 Terraform layout

```
bootstrap/                 applied once by hand
  state bucket, DynamoDB lock table, OIDC provider, role-terraform

modules/
  network/                 VPC, subnets, route tables, IGW, regional NAT,
                           S3 endpoint, Route 53 zone, both ACM certs
  security/                security groups, IAM roles and policies
  data/                    RDS Multi-AZ, subnet group, Secrets Manager
  compute/                 launch template, ASGs, ALB, target groups
  identity/                Cognito pool, app client, triggers
  messaging/               SNS topic, EventBridge schedule, Lambdas
  delivery/                CloudFront distribution, OAC, frontend bucket
  pipeline/                CodePipeline, CodeBuild, CodeDeploy, ECR
  observability/           log groups, alarms, dashboard

envs/
  prod/
```

Network and data hold separate state from compute and pipeline, wired together by `terraform_remote_state`. A security group change should never produce a plan that touches the database.

The `network` module needs a second provider alias for us-east-1 to create `cert-cloudfront`.

---

## 13. Diagram layers

Draw in this order. Each layer adds only its own arrows.

**Layer 1 — Network shell.** VPC boundary labelled `10.0.0.0/16`. Two AZ columns. Six subnet boxes per §3.2. Internet gateway on the VPC edge. **The regional NAT gateway is drawn at VPC level, spanning both AZ columns — not inside a subnet.**

**Layer 2 — Components.** Place every row of §4 into its subnet. ALB straddles both public subnets. Both ASGs straddle both app subnets. RDS appears as two equal boxes in `sn-data-a` and `sn-data-b`, labelled *primary* and *standby (not readable)*, with a note that the roles swap after failover. Cognito, SNS, S3, ECR, CloudFront, Route 53, and EventBridge sit outside the VPC boundary as regional or global services.

**Layer 3 — Request path.** Solid arrows:
```
Browser →443→ CloudFront → S3 (frontend assets)
Browser →443→ ALB →8080→ live target group → EC2 →5432→ RDS primary
RDS primary ⇄ synchronous replication ⇄ RDS standby
```

**Layer 4 — Supporting flows.** Dashed arrows, each labelled:
```
1. Browser        → Cognito Hosted UI          (auth, outside VPC)
2. Cognito        → fn-post-confirmation → RDS (signup)
3. EC2            → NAT → IGW → internet       (ECR pull, OS updates)
4. EC2            → vpce-s3 → S3               (profile pics, bypasses NAT)
5. Browser        → S3                         (pre-signed PUT/GET, direct)
6. EC2            → SNS → user email           (event notifications)
7. EventBridge    → fn-reminder-dispatcher → RDS → SNS (weekly reminders)
8. EC2            → Secrets Manager            (DB credentials at boot)
```

**Layer 5 — Deployment path.** Separate colour, ideally a second diagram:
```
GitHub → CodePipeline → CodeBuild → ECR
                     → CodeDeploy → asg-green → tg-green
                                  → listener swap
                                  → terminate asg-blue
```

**Layer 6 — Security group boundaries.** Overlay `sg-alb`, `sg-app`, `sg-data`, `sg-lambda` as dashed enclosures around the resources they protect. Label each allowed edge with its port.

Do not attempt all six layers in one image. Layers 1–3 make the primary architecture diagram; 4 and 5 are their own diagrams; 6 is a separate security view.

---

## 14. Observability

| Type | Resource | Threshold |
|---|---|---|
| Alarm | ALB 5xx rate | > 10 in 5 min → rollback trigger |
| Alarm | Unhealthy host count | ≥ 1 for 2 min |
| Alarm | ALB target response time p95 | > 2s for 5 min |
| Alarm | RDS CPU | > 80% for 10 min |
| Alarm | RDS free storage | < 20% |
| Alarm | RDS connections | > 80% of max |
| Alarm | **RDS failover event** | any occurrence → notify |
| Alarm | EC2 ASG CPU | > 85% for 10 min |
| Alarm | Estimated charges | > $80/month |
| Log group | `/hisaab/api` | 30 day retention |
| Log group | `/aws/lambda/*` | 30 day retention |
| Log group | `/hisaab/vpc-flow-logs` | 14 day retention |

Application logs ship via the CloudWatch agent on the instance. Container stdout goes to the `awslogs` Docker driver.

The failover alarm subscribes to the RDS event category `failover`. A silent automatic failover that nobody noticed is how you discover six months later that it has been happening weekly.

---

## 15. Cost estimate

Approximate monthly, us-west-2, low traffic, production only. Verify against the AWS pricing calculator before committing.

| Item | USD/month |
|---|---|
| Regional NAT gateway (2 active AZs) | 66 |
| ALB | 16–25 |
| 2× t4g.small | 25 |
| RDS db.t4g.micro Multi-AZ + 20 GB gp3 | 28 |
| Public IPv4 addresses | 7 |
| Route 53 hosted zone | 0.50 |
| CloudFront | ~0 (free tier) |
| ACM certificates | 0 |
| ECR, S3, SNS, Cognito, CloudWatch | ~3 |
| **Total** | **~146–155** |

Deploys briefly double instance count; at ten minutes per deploy this is negligible.

The two largest lines are the NAT gateway and the ALB, neither of which scales down with low traffic. **Set the billing alarm before the first apply, not after.**

---

## 16. Decision log

| # | Decision | Rationale |
|---|---|---|
| D1 | Three subnet tiers, not two | Isolates the database at the route table and NACL level; subnets cost nothing |
| D2 | Regional NAT over two zonal NATs | Identical cost at two active AZs, but one shared route table instead of two, and automatic AZ expansion |
| D3 | Blue/green over instance refresh | Instant rollback, no mixed-version window, old fleet stays warm during cutover |
| D4 | Blue/green split by version, not AZ | Splitting by AZ would leave the app single-zone permanently and put half of all deploys across an AZ boundary from RDS |
| D5 | ELB health checks, not EC2 | EC2 checks pass while the container is dead |
| D6 | Commit SHA image tags, never `latest` | Rollback requires an immutable, versioned artifact |
| D7 | S3 gateway endpoint, no interface endpoints | Gateway endpoint is free; interface endpoints would cost more than the NAT they replace |
| D8 | Cognito `preferred_username` | Cognito enforces uniqueness natively, avoiding a second uniqueness mechanism |
| D9 | Cognito prefix domain, not custom | A custom auth domain needs a third certificate in us-east-1 |
| D10 | Separate infra and app pipelines | Prevents a code deploy from planning against the database |
| D11 | Multi-AZ RDS | Redundant NAT egress protecting a single-AZ database is incoherent. Multi-AZ is what makes the two-zone posture actually survive an AZ loss |
| D12 | SNS filter policies for per-user targeting | Keeps to the specified service without a per-user topic explosion |
| D13 | DNS delegated to Route 53 | Alias records are Route 53-only, apex CNAMEs are invalid DNS, and hand-managed ACM validation records cause silent renewal failures |
| D14 | Two ACM certificates | CloudFront reads certificates only from us-east-1; certificates cannot be copied between regions |
| D15 | Production only, no dev environment | The NAT gateway and ALB dominate the bill and do not scale down; a mirrored dev environment would roughly double it |
| D16 | Schema migrations outside Terraform | A `psql` provisioner in a `null_resource` breaks state and re-runs unpredictably |

---

## 17. Open items

1. **Migration tooling.** Flyway, golang-migrate, or a manual `psql` step run through SSM. Determines whether the app pipeline gains a migration stage before deploy. Blocks nothing until phase 3.
2. **Frontend hosting confirmation.** S3 plus CloudFront is specified throughout. If the SPA is instead served from the ALB, then `hisaab-frontend-prod`, the CloudFront distribution, the `delivery` module, and `cert-cloudfront` all drop out — and the CORS requirement in §3.7 disappears with them. Cheap to reverse now, expensive later.
3. **Database access from a laptop.** SSM Session Manager port forwarding to RDS works and needs no bastion. Confirm this is an acceptable workflow before ruling out a bastion permanently.
4. **Log retention.** 30 days is a default, not a decision. Cheap at this volume either way.
5. **Backup restore drill.** Backups are configured but untested. Restore a snapshot into a scratch instance once, before the app holds real data.
