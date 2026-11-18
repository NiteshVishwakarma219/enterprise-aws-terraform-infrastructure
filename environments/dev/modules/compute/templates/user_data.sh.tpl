#!/bin/bash

set -euxo pipefail

exec > >(tee -a /var/log/nexops-user-data.log | logger -t nexops-user-data -s 2>/dev/console) 2>&1

echo "=================================================="
echo " NexOps Enterprise Platform Bootstrap"
echo "=================================================="

# --------------------------------------------------
# BASIC SYSTEM SETUP
# --------------------------------------------------

dnf update -y

# Docker is available from Amazon Linux repositories.
dnf install -y docker jq awscli nginx

systemctl enable --now docker
systemctl enable nginx

echo "Docker status:"
systemctl is-active docker

# --------------------------------------------------
# APPLICATION IMAGES (WITH RETRY FOR DOCKER HUB TIMEOUTS)
# --------------------------------------------------

pull_image() {
  local img="$1"
  for i in $(seq 1 6); do
    echo "Pulling $img (attempt $i/6)..."
    if docker pull "$img"; then
      echo "Successfully pulled $img"
      return 0
    fi
    echo "Pull failed for $img, restarting docker & retrying in 15s..."
    systemctl restart docker
    sleep 15
  done
  echo "ERROR: Could not pull $img after 6 attempts"
  return 1
}

pull_image "${backend_image}"
pull_image "${frontend_image}"

# --------------------------------------------------
# DOCKER NETWORK
# --------------------------------------------------

docker network create nexops-network 2>/dev/null || true

# --------------------------------------------------
# READ DATABASE SECRET
# --------------------------------------------------

echo "Reading database secret..."

SECRET_JSON=""

for i in $(seq 1 40); do

  if SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "${database_secret_name}" \
    --region "${aws_region}" \
    --query SecretString \
    --output text 2>/dev/null) && [ -n "$SECRET_JSON" ]; then
    echo "Secret retrieved."
    break
  fi

  echo "Secret not available yet. Attempt $i/40"
  sleep 15

done

if [ -z "$SECRET_JSON" ]; then
  echo "ERROR: database secret could not be read"
  exit 1
fi

DB_USERNAME=$(echo "$SECRET_JSON" | jq -r '.username')
DB_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.password')
DB_DATABASE=$(echo "$SECRET_JSON" | jq -r '.database')
DB_HOST=$(echo "$SECRET_JSON" | jq -r '.host')
DB_PORT=$(echo "$SECRET_JSON" | jq -r '.port')
JWT_SECRET=$(echo "$SECRET_JSON" | jq -r '.jwt_secret')

ADMIN_DEMO_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.admin_demo')
HR_DEMO_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.hr_demo')
MANAGER_DEMO_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.manager_demo')
EMPLOYEE_DEMO_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.employee_demo')

echo "Database host: $DB_HOST"
echo "Database name: $DB_DATABASE"
echo "Database port: $DB_PORT"

# --------------------------------------------------
# DATABASE URL
# --------------------------------------------------

DATABASE_URL="postgresql://$DB_USERNAME:$DB_PASSWORD@$DB_HOST:$DB_PORT/$DB_DATABASE"

# --------------------------------------------------
# REMOVE OLD CONTAINERS
# --------------------------------------------------

docker rm -f nexops-backend 2>/dev/null || true
docker rm -f nexops-frontend 2>/dev/null || true

# --------------------------------------------------
# START BACKEND
# --------------------------------------------------

echo "Starting backend..."

docker run -d \
  --name nexops-backend \
  --restart unless-stopped \
  --network nexops-network \
  --network-alias backend \
  -p 8000:8000 \
  -e NODE_ENV=production \
  -e PORT=8000 \
  -e DATABASE_URL="$DATABASE_URL" \
  -e DIRECT_URL="$DATABASE_URL" \
  -e JWT_SECRET="$JWT_SECRET" \
  "${backend_image}"

# --------------------------------------------------
# START FRONTEND
# --------------------------------------------------

echo "Starting frontend..."

docker run -d \
  --name nexops-frontend \
  --restart unless-stopped \
  --network nexops-network \
  -p 3000:80 \
  "${frontend_image}"

# --------------------------------------------------
# SHOW CONTAINERS
# --------------------------------------------------

echo "Docker containers:"
docker ps -a

# --------------------------------------------------
# WAIT FOR BACKEND
# --------------------------------------------------

echo "Waiting for backend..."

BACKEND_READY=false

for i in $(seq 1 60); do

  if curl -fsS http://127.0.0.1:8000/api/health >/dev/null 2>&1; then
    BACKEND_READY=true
    echo "Backend is healthy."
    break
  fi

  echo "Backend not ready yet. Attempt $i/60"
  sleep 3

done

if [ "$BACKEND_READY" != "true" ]; then

  echo "=================================================="
  echo "ERROR: Backend did not become healthy"
  echo "=================================================="

  echo "Backend container status:"
  docker ps -a

  echo "Backend logs:"
  docker logs nexops-backend || true

  exit 1
fi

# --------------------------------------------------
# DATABASE SCHEMA
# --------------------------------------------------

echo "Updating database schema..."

# Two ASG instances boot at the same time and may push the schema
# concurrently, so retry instead of failing the whole bootstrap.
for i in $(seq 1 5); do
  if docker exec nexops-backend npx prisma db push --skip-generate; then
    echo "Schema is up to date."
    break
  fi
  echo "prisma db push failed (attempt $i/5), retrying..."
  sleep $((RANDOM % 10 + 5))
done

# --------------------------------------------------
# DEMO USERS
# --------------------------------------------------

echo "Creating demo users..."

docker exec \
  -e ADMIN_DEMO_PASSWORD="$ADMIN_DEMO_PASSWORD" \
  -e HR_DEMO_PASSWORD="$HR_DEMO_PASSWORD" \
  -e MANAGER_DEMO_PASSWORD="$MANAGER_DEMO_PASSWORD" \
  -e EMPLOYEE_DEMO_PASSWORD="$EMPLOYEE_DEMO_PASSWORD" \
  nexops-backend \
  node -e '
const { PrismaClient } = require("@prisma/client");
const bcrypt = require("bcryptjs");

const prisma = new PrismaClient();

const users = [
  {
    email: "admin@nexops.com",
    password: process.env.ADMIN_DEMO_PASSWORD,
    fullName: "System Admin",
    role: "admin"
  },
  {
    email: "hr@nexops.com",
    password: process.env.HR_DEMO_PASSWORD,
    fullName: "HR Manager",
    role: "hr"
  },
  {
    email: "manager@nexops.com",
    password: process.env.MANAGER_DEMO_PASSWORD,
    fullName: "Team Manager",
    role: "manager"
  },
  {
    email: "employee@nexops.com",
    password: process.env.EMPLOYEE_DEMO_PASSWORD,
    fullName: "Demo Employee",
    role: "employee"
  }
];

(async () => {

  for (const user of users) {

    const hashedPassword = await bcrypt.hash(user.password, 12);

    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
    await prisma.user.upsert({
      where: {
        email: user.email
      },
      update: {
        password: hashedPassword,
        fullName: user.fullName,
        role: user.role,
        isActive: true
      },
      create: {
        email: user.email,
        password: hashedPassword,
        fullName: user.fullName,
        role: user.role,
        isActive: true
      }
    });
        break;
      } catch (e) {
        // P2002 = unique constraint: the other instance created it first. Retry (becomes an update).
        if (e.code !== "P2002" || attempt === 3) throw e;
        await new Promise(r => setTimeout(r, 1000));
      }
    }

  }

  console.log("Demo accounts ensured.");

  await prisma.$disconnect();

})().catch(async (error) => {

  console.error(error);

  await prisma.$disconnect();

  process.exit(1);

});
'

# --------------------------------------------------
# NGINX CONFIGURATION
# --------------------------------------------------

echo "Configuring Nginx..."

cat > /etc/nginx/conf.d/nexops.conf <<'NGINX'

server {

    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;

    location / {

        proxy_pass http://127.0.0.1:3000;

        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

    }

    location /api/ {

        proxy_pass http://127.0.0.1:8000;

        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

    }

    location /uploads/ {

        proxy_pass http://127.0.0.1:8000;

        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

    }

}

NGINX

# --------------------------------------------------
# TEST NGINX
# --------------------------------------------------

nginx -t

systemctl restart nginx

systemctl enable nginx

# --------------------------------------------------
# LOCAL HEALTH CHECKS
# --------------------------------------------------

echo "Testing Nginx..."

curl -fsS http://127.0.0.1/ >/dev/null

echo "Testing API..."

curl -fsS http://127.0.0.1/api/health

# --------------------------------------------------
# FINAL STATUS
# --------------------------------------------------

echo ""
echo "=================================================="
echo " NexOps Bootstrap Completed Successfully"
echo "=================================================="

echo "Docker:"
systemctl is-active docker

echo "Nginx:"
systemctl is-active nginx

echo "Containers:"
docker ps

echo "Listening ports:"
ss -lntp

echo "Bootstrap completed successfully." \
  > /var/log/nexops-bootstrap.log