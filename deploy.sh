#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CONFIGURATION - UPDATED WITH YOUR PARAMETERS
# ==============================================================================
AWS_REGION="eu-north-1"
INSTANCE_TYPE="t3.micro"
AMI_ID="ami-0aba19e56f3eaec05"
KEY_NAME="demoserver"
DOMAIN_NAME="app.ghostqrx.org"
EMAIL="admin@ghostqrx.org"
ECR_IMAGE_URI="123456789012.dkr.ecr.eu-north-1.amazonaws.com/my-app:latest"
CONTAINER_PORT="8080"
APP_NAME="my-container-app"

ROLE_NAME="EC2-ECR-ReadAccess-Role"
PROFILE_NAME="EC2-ECR-ReadAccess-Profile"
SG_NAME="ec2-web-app-sg"

echo "=== STEP 1: Creating IAM Role for ECR Access ==="
if ! aws iam get-role --role-name "${ROLE_NAME}" &>/dev/null; then
    aws iam create-role \
        --role-name "${ROLE_NAME}" \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "ec2.amazonaws.com"},
                "Action": "sts:AssumeRole"
            }]
        }'
    
    aws iam attach-role-policy \
        --role-name "${ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"

    aws iam create-instance-profile --instance-profile-name "${PROFILE_NAME}"
    aws iam add-role-to-instance-profile --instance-profile-name "${PROFILE_NAME}" --role-name "${ROLE_NAME}"
    echo "Waiting 10s for IAM propagation..."
    sleep 10
fi

echo "=== STEP 2: Setting up Security Group ==="
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text --region "${AWS_REGION}")

SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" --query "SecurityGroups[0].GroupId" --output text --region "${AWS_REGION}" 2>/dev/null || echo "None")

if [ "${SG_ID}" == "None" ] || [ -z "${SG_ID}" ]; then
    SG_ID=$(aws ec2 create-security-group \
        --group-name "${SG_NAME}" \
        --description "Security group for web server and SSH" \
        --vpc-id "${VPC_ID}" \
        --query 'GroupId' --output text --region "${AWS_REGION}")

    aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "${AWS_REGION}"
    aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "${AWS_REGION}"
    aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --protocol tcp --port 443 --cidr 0.0.0.0/0 --region "${AWS_REGION}"
fi

echo "=== STEP 3: Preparing EC2 User Data Setup Script ==="
cat << 'EOF' > user_data.sh
#!/usr/bin/env bash
set -euo pipefail

# Injected environment variables
DOMAIN_NAME="__DOMAIN_NAME__"
EMAIL="__EMAIL__"
AWS_REGION="__AWS_REGION__"
ECR_IMAGE_URI="__ECR_IMAGE_URI__"
CONTAINER_PORT="__CONTAINER_PORT__"
APP_NAME="__APP_NAME__"

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
EOF

# Substitute config values into user_data.sh
sed -i "s|__DOMAIN_NAME__|${DOMAIN_NAME}|g" user_data.sh
sed -i "s|__EMAIL__|${EMAIL}|g" user_data.sh
sed -i "s|__AWS_REGION__|${AWS_REGION}|g" user_data.sh
sed -i "s|__ECR_IMAGE_URI__|${ECR_IMAGE_URI}|g" user_data.sh
sed -i "s|__CONTAINER_PORT__|${CONTAINER_PORT}|g" user_data.sh
sed -i "s|__APP_NAME__|${APP_NAME}|g" user_data.sh

echo "=== STEP 4: Launching EC2 Instance in ${AWS_REGION} ==="
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "${AMI_ID}" \
    --instance-type "${INSTANCE_TYPE}" \
    --key-name "${KEY_NAME}" \
    --security-group-ids "${SG_ID}" \
    --iam-instance-profile Name="${PROFILE_NAME}" \
    --user-data file://user_data.sh \
    --query 'Instances[0].InstanceId' \
    --output text \
    --region "${AWS_REGION}")

echo "EC2 Instance launched with ID: ${INSTANCE_ID}"
echo "Waiting for EC2 Instance to obtain a Public IP..."
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region "${AWS_REGION}")

echo "========================================================================="
echo "Deployment initiated!"
echo "Server Public IP: ${PUBLIC_IP}"
echo "Action Required: Point the A-Record for ${DOMAIN_NAME} to ${PUBLIC_IP}"
echo "========================================================================="