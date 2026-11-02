#!/bin/bash
set -euo pipefail

mkdir -p /opt/mi-app /var/log/calculadora
chmod 777 /var/log/calculadora

if [ -f /opt/mi-app/docker-compose.yml ]; then
  cd /opt/mi-app
  docker compose down --remove-orphans || true
fi
