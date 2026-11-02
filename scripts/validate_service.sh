#!/bin/bash
set -euo pipefail

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:3000/api/health >/dev/null; then
    echo "validate_service: OK"
    exit 0
  fi
  sleep 10
done

echo "validate_service: FAILED" >&2
exit 1
