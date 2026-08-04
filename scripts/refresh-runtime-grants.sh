#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export ORACLE_PWD="$(tr -d '\r\n' < secrets/oracle_password.txt)"
./scripts/configure-container-access.sh
docker compose exec -T oracle bash /project/setup/003-runtime-grants.sh
