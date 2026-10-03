#!/bin/sh
# Loads the bundled Docker images (no Internet access needed), then starts
# the services in the background. Stop them with: docker compose down
set -eu
cd "$(dirname "$0")"
echo "==> Loading Docker images"
gunzip -c images.tar.gz | docker load
docker compose up -d
docker compose ps
