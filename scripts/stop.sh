#!/bin/bash
set -euo pipefail

if docker ps -a --format '{{.Names}}' | grep -q '^hisaab-api$'; then
  docker stop hisaab-api
  docker rm hisaab-api
else
  echo "No existing hisaab-api container — nothing to stop."
fi
