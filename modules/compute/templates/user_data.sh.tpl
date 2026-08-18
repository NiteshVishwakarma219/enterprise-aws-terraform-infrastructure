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
# APPLICATION IMAGES
# --------------------------------------------------

echo "Pulling backend image..."
docker pull ${backend_image}

echo "Pulling frontend image..."
docker pull ${frontend_image}

# --------------------------------------------------
# DOCKER NETWORK
# --------------------------------------------------

docker network create nexops-network 2>/dev/null || true

# --------------------------------------------------
# READ DATABASE SECRET
# --------------------------------------------------

echo "Reading database secret..."

SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "${database_secret_name}" \
  --region "${aws_region}" \
  --query SecretString \
  --output text)

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

docker exec nexops-backend \
  npx prisma db push --skip-generate

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