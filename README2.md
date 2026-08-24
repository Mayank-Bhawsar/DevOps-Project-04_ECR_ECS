# DevOps Project 04 — Django on AWS ECR + ECS Fargate

This repository deploys a small Django “Hello World” app as a Docker image in Amazon ECR, then runs it on Amazon ECS Fargate behind an Application Load Balancer. Infrastructure is defined in Terraform (`ap-south-1`). Images are built and pushed by GitHub Actions on pushes to `master`.

The original `README.md` is a generic ECS/ECR tutorial. This file describes **this codebase as it exists**.

---

## What you get

| Layer | What this repo actually does |
| --- | --- |
| App | Django project `hello_world_django_app` with a single HTML page at `/hello/` |
| Runtime | Multi-stage Docker image, Gunicorn on port `8000`, non-root user |
| Registry | ECR repository `django-app-repo` (scan on push, mutable tags) |
| Compute | ECS Fargate cluster `django-production-cluster`, service desired count `2` |
| Network | VPC `10.0.0.0/16`, 2 public + 2 private subnets, Internet Gateway, **NAT EC2 instance** (not NAT Gateway) |
| Ingress | Internet-facing ALB on HTTP `:80` → target group IP mode on `:8000` |
| Secrets | Secrets Manager secret `devops-04-django-secrets` injected as `DJANGO_SECRET_KEY` |
| Scale | Application Auto Scaling: min `2`, max `4`, target CPU `70%` |
| Logs | CloudWatch log group `/ecs/django-app` (7-day retention) |
| CI | GitHub Actions OIDC → ECR login → `docker build` + push `:$SHA` and `:latest` |

---

## Architecture (request path)

```
Internet
   │  HTTP :80
   ▼
Application Load Balancer  (public subnets, sg: devops-04-alb-sg)
   │  forward to target group devops-04-tg (ip, :8000, health path "/")
   ▼
ECS Fargate tasks  (private subnets, sg: devops-04-ecs-tasks-sg, :8000 from ALB only)
   │  image: <account>.dkr.ecr.ap-south-1.amazonaws.com/django-app-repo:latest
   │  env: DJANGO_SECRET_KEY from Secrets Manager
   ▼
Gunicorn → Django WSGI  (hello_world_django_app.wsgi:application)
```

Outbound from private tasks (ECR pulls, Secrets Manager, CloudWatch, apt/curl in image healthcheck) goes:

```
Private subnet → NAT instance (t3.micro in public subnet[0], source/dest check off) → IGW → Internet
```

---

## Repository layout

```
.
├── hello_world_django_app/     # Django project package
│   ├── settings.py             # SECRET_KEY from env; SQLite; DEBUG=True; ALLOWED_HOSTS=["*"]
│   ├── urls.py                 # /admin/, /hello/
│   ├── views.py                # hello_world → "<html><body>Hello World</body></html>"
│   ├── wsgi.py                 # used by Gunicorn
│   └── asgi.py                 # unused in production CMD
├── manage.py
├── requirements.txt            # django (unpinned), gunicorn==21.2.0
├── Dockerfile                  # python:3.9-slim multi-stage; collectstatic; gunicorn
├── .github/workflows/deploy.yml
├── terraform/                  # AWS infrastructure
│   ├── backend.tf
│   ├── providers.tf
│   ├── ecr.tf
│   ├── vpc.tf
│   ├── alb.tf
│   ├── iam.tf
│   ├── secrets.tf
│   ├── ecs.tf
│   └── autoscaling.tf
├── README.md                   # generic tutorial (not repo-accurate)
└── README2.md                  # this file
```

There is no `docker-compose.yml`, no extra Django apps, no RDS, no TLS listener, and no ECS service update step in CI.

---

## Application

### Endpoints

| Path | Handler | Response |
| --- | --- | --- |
| `/hello/` | `hello_world_django_app.views.hello_world` | `200` HTML “Hello World” |
| `/admin/` | Django admin | login (SQLite users; empty until you migrate + create superuser) |
| `/` | not defined | Django `404` |
| `/health/` | not defined | Django `404` |

### Settings (`hello_world_django_app/settings.py`)

- `SECRET_KEY` from `DJANGO_SECRET_KEY`, fallback string for local only.
- `DEBUG = True` (not production-hardened).
- `ALLOWED_HOSTS = ["*"]`.
- Database: SQLite at `db.sqlite3` (ephemeral on Fargate; lost on task replace).
- `STATIC_ROOT = BASE_DIR / "static"` (collected at image build).

### Local run

```bash
python -m venv .venv
# Windows: .venv\Scripts\activate
pip install -r requirements.txt
python manage.py migrate
python manage.py runserver
# open http://127.0.0.1:8000/hello/
```

---

## Container image

`Dockerfile` is a two-stage build:

1. **builder** — `python:3.9-slim`, `build-essential` + `libpq-dev`, venv, `pip install -r requirements.txt`.
2. **production** — copy venv, install `libpq5` + `curl`, user `django`, copy app, `collectstatic`, `EXPOSE 8000`.

Start command:

```text
gunicorn --bind 0.0.0.0:8000 --workers 3 --timeout 120 \
  --access-logfile - --error-logfile - \
  hello_world_django_app.wsgi:application
```

Image healthcheck:

```text
curl -f http://localhost:8000/health/
```

That path is **not** implemented in `urls.py`. Docker/`HEALTHCHECK` and any orchestrator that honors it will see an unhealthy container. ECS/ALB currently use a **different** check (see Known gaps).

Build and run locally:

```bash
docker build -t django-app:local .
docker run --rm -p 8000:8000 -e DJANGO_SECRET_KEY=dev django-app:local
# http://localhost:8000/hello/
```

---

## Terraform (region `ap-south-1`)

Requires Terraform `>= 1.5.0` and AWS provider `~> 6.0`.

### Remote state (`terraform/backend.tf`)

| Setting | Value |
| --- | --- |
| Backend | S3 |
| Bucket | `devops-project-01-tfstate-q919ah` |
| Key | `devops-project-04/terraform.tfstate` |
| Region | `ap-south-1` |
| Encrypt | `true` |
| Lock | `use_lockfile = true` (S3 native lock; DynamoDB lock commented out) |

The bucket must already exist; this project does not create it.

### Networking (`vpc.tf`)

- VPC `devops-project-04-vpc`: `10.0.0.0/16`, DNS hostnames + support on.
- Public subnets: `10.0.0.0/24`, `10.0.1.0/24` (first two AZs), public IPs on launch.
- Private subnets: `10.0.10.0/24`, `10.0.11.0/24`.
- IGW + public route table (`0.0.0.0/0` → IGW).
- NAT: Amazon Linux 2023 `t3.micro` in `public[0]`, `source_dest_check = false`, iptables `MASQUERADE`.
- Private route: `0.0.0.0/0` → NAT instance ENI.
- NAT SG allows all from VPC CIDR, all egress.

NAT instance is cheaper than NAT Gateway but is a single AZ / single instance; private egress dies if that instance is stopped.

### Load balancer (`alb.tf`)

- SG `devops-04-alb-sg`: inbound TCP `80` from `0.0.0.0/0`.
- ALB `devops-4-alb` (AWS name max length), internet-facing, public subnets.
- Target group `devops-04-tg`: HTTP, port `8000`, `target_type = ip` (required for Fargate `awsvpc`).
- Health check: HTTP `/`, matcher `200`, interval 30s, timeout 3s, healthy 3 / unhealthy 2.
- Listener: HTTP `:80` forward to the target group. **No HTTPS / ACM.**

### ECR (`ecr.tf`)

- Repository name: `django-app-repo` (must match CI `ECR_REPOSITORY`).
- `force_delete = true`, `MUTABLE` tags, `scan_on_push = true`.
- Tag: `Project = devops-project-04`.

### IAM (`iam.tf`)

- **Execution role** `devops-04-ecs-execution-role`: ECS tasks assume role + `AmazonECSTaskExecutionRolePolicy` + `secretsmanager:GetSecretValue` on the app secret (pull image, write logs, inject secrets at start).
- **Task role** `devops-04-ecs-task-role`: assume role only; **no extra app policies**. SQLite needs none.

### Secrets (`secrets.tf`)

- Secret name: `devops-04-django-secrets`.
- Initial JSON: `{ "DJANGO_SECRET_KEY": "placeholder-insecure-dev-key-change-me-in-console" }`.
- `lifecycle.ignore_changes = [secret_string]` so later Console/CLI updates are not overwritten.
- `recovery_window_in_days = 0` (immediate delete on destroy).

ECS injects `DJANGO_SECRET_KEY` via Secrets Manager JSON key syntax:

```text
<secret-arn>:DJANGO_SECRET_KEY::
```

### ECS (`ecs.tf`)

| Resource | Name / value |
| --- | --- |
| Cluster | `django-production-cluster` |
| Log group | `/ecs/django-app`, 7 days |
| Task family | `django-app-task` |
| Launch | Fargate, `awsvpc`, CPU `256`, memory `512` |
| Container | `django-app`, image `:latest`, port `8000` |
| Service | `django-production-service`, desired `2` |
| Network | private subnets, `assign_public_ip = false`, SG `devops-04-ecs-tasks-sg` |
| SG ingress | `:8000` only from ALB SG |
| Lifecycle | `ignore_changes` on `desired_count` and `task_definition` (autoscaling + CI-updated defs won’t be reverted by Terraform apply for those fields) |

### Auto scaling (`autoscaling.tf`)

- Min `2`, max `4` desired tasks.
- Target tracking: `ECSServiceAverageCPUUtilization` = `70`.
- Scale-out cooldown `60s`, scale-in `300s`.

### Apply

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

AWS credentials must be able to create VPC, EC2, ALB, ECS, ECR, IAM, Secrets Manager, CloudWatch, and Application Auto Scaling in `ap-south-1`.

After apply, open:

```text
http://<alb-dns>/hello/
```

ALB DNS is not currently an output in Terraform; look it up in the EC2/ELB console or add an `output`.

---

## CI/CD (GitHub Actions)

File: `.github/workflows/deploy.yml`

- **Trigger:** `push` to `master` only.
- **Permissions:** `id-token: write`, `contents: read` (OIDC).
- **Auth:** `aws-actions/configure-aws-credentials@v4` with:
  - `secrets.AWS_ROLE_TO_ASSUME`
  - `secrets.AWS_REGION` (should be `ap-south-1`)
- **ECR:** `aws-actions/amazon-ecr-login@v2`
- **Build:** tags `$ECR_REGISTRY/django-app-repo:$GITHUB_SHA` and `:latest`, then `docker push --all-tags`.

**Not in the workflow:** Terraform apply, ECS `update-service --force-new-deployment`, or registering a new task definition. Because the task definition is pinned to `:latest` **and** the ECS service has `lifecycle.ignore_changes = [task_definition]`, a new image with the same tag may **not** roll out until you force a new deployment (or change the service to use an immutable tag + new task definition).

Required GitHub secrets:

1. `AWS_ROLE_TO_ASSUME` — IAM role ARN trusted by GitHub OIDC (`token.actions.githubusercontent.com`).
2. `AWS_REGION` — `ap-south-1`.

That role needs ECR auth + push to `django-app-repo`. Terraform does **not** create the GitHub OIDC provider or this role.

---

## End-to-end deploy sequence

1. Ensure S3 state bucket `devops-project-01-tfstate-q919ah` exists in `ap-south-1`.
2. `terraform init && terraform apply` (creates VPC, NAT instance, ALB, ECR, ECS, IAM, secret, autoscaling).
3. Put a real `DJANGO_SECRET_KEY` in Secrets Manager (Console or CLI); Terraform will not overwrite it after first apply.
4. Configure GitHub OIDC + secrets; push to `master` so the image exists in ECR.
5. Force ECS to pull `:latest` if tasks were created before the first successful push:

   ```bash
   aws ecs update-service \
     --cluster django-production-cluster \
     --service django-production-service \
     --force-new-deployment \
     --region ap-south-1
   ```

6. Hit `http://<alb-dns>/hello/`.

If ECS starts before any image is in ECR, tasks fail with image pull errors until CI (or a local `docker push`) succeeds.

---

## Known gaps (code vs “production-ready”)

These are real mismatches in this repo, not generic advice:

1. **ALB health check path is `/`**, which Django does not route → `404` → targets stay **unhealthy**. App URL is `/hello/`.
2. **Dockerfile `HEALTHCHECK` uses `/health/`**, which also does not exist.
3. **`DEBUG = True`** and **`ALLOWED_HOSTS = ["*"]`** in settings used in the image.
4. **SQLite on Fargate** is not shared or durable; admin/users/data do not persist across tasks.
5. **CI does not update ECS**; `:latest` + `ignore_changes` on `task_definition` can leave old tasks running.
6. **HTTP only** — no ACM, no redirect to HTTPS.
7. **NAT instance** is a single `t3.micro` in one AZ.
8. **Placeholder secret** until you change it in the console.
9. **Django version unpinned** in `requirements.txt`; image builds whatever latest `django` pip resolves.
10. **`libpq-dev` / `libpq5` in Docker** but the app does not use PostgreSQL.

---

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| ALB 502 / unhealthy targets | Health check `/` returns 404; change TG path to `/hello/` or add a `/` or `/health/` view that returns 200 |
| Tasks `CannotPullContainerError` | Image never pushed, wrong region, or private subnet cannot reach ECR (NAT instance down / SG) |
| Tasks start then die | Missing secret, wrong JSON key, execution role cannot `GetSecretValue` |
| Push to `master` does nothing on ECS | Workflow only pushes ECR; force new deployment |
| App works locally on `/hello/` but ALB never registers | Same health-check path issue |
| Terraform cannot init backend | S3 bucket name/region/permissions |

CloudWatch logs: `/ecs/django-app`, stream prefix `django`.

---

## Destroy

```bash
cd terraform
terraform destroy
```

ECR `force_delete = true` allows the repo to be removed even with images. Secret recovery window is `0`. Confirm NAT instance, ALB, and VPC are gone in the console. Remote state in S3 is **not** deleted by destroy.
