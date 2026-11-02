#!/bin/bash
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive
REGION="${aws_region}"
PARAM_NAME="${cloudwatch_parameter_name}"

apt-get update -y
apt-get install -y docker.io curl unzip jq ruby wget
systemctl enable --now docker
usermod -aG docker ubuntu || true

# Docker Compose plugin
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# AWS CLI v2
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update

# CodeDeploy agent
wget -q "https://aws-codedeploy-$REGION.s3.$REGION.amazonaws.com/latest/install" -O /tmp/install
chmod +x /tmp/install
/tmp/install auto

# CloudWatch agent
wget -q "https://s3.$REGION.amazonaws.com/amazoncloudwatch-agent-$REGION/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb" \
  -O /tmp/amazon-cloudwatch-agent.deb
dpkg -i /tmp/amazon-cloudwatch-agent.deb || apt-get install -f -y

# Directorio de logs compartido por backend y frontend
mkdir -p /var/log/calculadora
chmod 777 /var/log/calculadora

# SSM Agent para Session Manager
snap install amazon-ssm-agent --classic || true
systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true

# Configurar el agente desde el parametro SSM
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s -c "ssm:$PARAM_NAME"

systemctl enable amazon-cloudwatch-agent
systemctl restart amazon-cloudwatch-agent
