#!/usr/bin/env bash
set -euo pipefail

# Injected environment variables
DOMAIN_NAME="app.ghostqrx.org"
EMAIL="admin@ghostqrx.org"
AWS_REGION="eu-north-1"
ECR_IMAGE_URI="123456789012.dkr.ecr.eu-north-1.amazonaws.com/my-app:latest"
CONTAINER_PORT="8080"
APP_NAME="my-container-app"

# 1. Update and install packages
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y docker.io awscli nginx certbot python3-certbot-nginx

systemctl start docker
systemctl enable docker
systemctl start nginx
systemctl enable nginx

# 2. Login to ECR and pull image
REGISTRY_URL="${ECR_IMAGE_URI%%/*}"
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${REGISTRY_URL}"
docker pull "${ECR_IMAGE_URI}"

# 3. Configure systemd for container auto-restart
cat <<SERVICE > /etc/systemd/system/${APP_NAME}.service
[Unit]
Description=${APP_NAME} Container Service
After=docker.service
Requires=docker.service

[Service]
Restart=always
RestartSec=5s
ExecStartPre=-/usr/bin/docker stop ${APP_NAME}
ExecStartPre=-/usr/bin/docker rm ${APP_NAME}
ExecStartPre=/bin/sh -c '/usr/bin/aws ecr get-login-password --region ${AWS_REGION} | /usr/bin/docker login --username AWS --password-stdin ${REGISTRY_URL}'
ExecStartPre=/usr/bin/docker pull ${ECR_IMAGE_URI}
ExecStart=/usr/bin/docker run --name ${APP_NAME} -p 127.0.0.1:${CONTAINER_PORT}:${CONTAINER_PORT} ${ECR_IMAGE_URI}
ExecStop=/usr/bin/docker stop -t 2 ${APP_NAME}

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable ${APP_NAME}.service
systemctl restart ${APP_NAME}.service

# 4. Configure Nginx Reverse Proxy
cat <<NGINX > /etc/nginx/sites-available/${APP_NAME}
server {
    listen 80;
    server_name ${DOMAIN_NAME};

    location / {
        proxy_pass http://127.0.0.1:${CONTAINER_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/${APP_NAME} /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

# 5. Acquire SSL via Certbot
certbot --nginx --non-interactive --agree-tos --email "${EMAIL}" -d "${DOMAIN_NAME}" --redirect || true
