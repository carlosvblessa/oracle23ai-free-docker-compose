#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

set -a
# shellcheck disable=SC1091
source .env
set +a

./scripts/configure-container-access.sh

export ORACLE_PWD="$(tr -d '\r\n' < secrets/oracle_password.txt)"
STAMP="$(date +%Y%m%d_%H%M%S)"
DUMP_FILE="${DB_SCHEMA_USER}_${STAMP}.dmp"
LOG_FILE="${DB_SCHEMA_USER}_${STAMP}.log"
CONTAINER_DIR=/opt/oracle/oradata/backups

mkdir -p backups

docker compose exec -T oracle bash -lc "mkdir -p '${CONTAINER_DIR}'"

docker compose exec -T oracle bash -lc '
  set -euo pipefail
  ADMIN_PASSWORD="$(cat /run/secrets/db_admin_password)"

  sqlplus -s -L "${DB_ADMIN_USER}/\"${ADMIN_PASSWORD}\"@//localhost:1521/FREEPDB1" <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
CREATE OR REPLACE DIRECTORY DOCKER_BACKUP_DIR AS '\''/opt/oracle/oradata/backups'\'';
GRANT READ, WRITE ON DIRECTORY DOCKER_BACKUP_DIR TO '${DB_SCHEMA_USER}';
EXIT
SQL
'

SCHEMA_PASSWORD="$(tr -d '\r\n' < secrets/db_schema_password.txt)"
docker compose exec -T oracle bash -lc \
  "expdp '${DB_SCHEMA_USER}/\"${SCHEMA_PASSWORD}\"@localhost:1521/FREEPDB1' schemas='${DB_SCHEMA_USER}' directory=DOCKER_BACKUP_DIR dumpfile='${DUMP_FILE}' logfile='${LOG_FILE}' reuse_dumpfiles=no"

docker compose cp "oracle:${CONTAINER_DIR}/${DUMP_FILE}" "backups/${DUMP_FILE}"
docker compose cp "oracle:${CONTAINER_DIR}/${LOG_FILE}" "backups/${LOG_FILE}"

printf 'Backup copiado para backups/%s\n' "$DUMP_FILE"
