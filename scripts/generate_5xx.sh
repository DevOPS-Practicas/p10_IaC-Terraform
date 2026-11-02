#!/bin/bash
# Genera trafico 5xx contra el listener de pruebas 8080.
# Uso: ./scripts/generate_5xx.sh <alb-dns> [segundos]
set -euo pipefail

ALB_DNS="${1:?Uso: generate_5xx.sh <alb-dns> [segundos]}"
DURATION="${2:-300}"
END=$((SECONDS + DURATION))

echo "Generando 5xx contra http://$ALB_DNS:8080/api/boom durante ${DURATION}s"
while [ "$SECONDS" -lt "$END" ]; do
  curl -s -o /dev/null "http://$ALB_DNS:8080/api/boom" || true
  sleep 0.5
done
echo "Fin del trafico 5xx"
