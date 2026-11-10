#!/bin/bash
set -euo pipefail

for _ in $(seq 1 10); do
  if curl -sf http://localhost:8080/health > /dev/null; then
    echo "hisaab-api is healthy."
    exit 0
  fi
  sleep 3
done

echo "hisaab-api did not become healthy in time."
exit 1
