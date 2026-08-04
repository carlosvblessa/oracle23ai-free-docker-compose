#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export ORACLE_PWD="$(tr -d '\r\n' < secrets/oracle_password.txt)"
docker compose exec -T oracle bash /opt/oracle/scripts/setup/003-runtime-grants.sh
