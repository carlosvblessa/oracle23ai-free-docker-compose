#!/usr/bin/env bash
set -Eeuo pipefail

SCHEMA_DIR=/project/schema
SCHEMA_PASSWORD="$(tr -d '\r\n' < /run/secrets/db_schema_password)"

shopt -s nullglob
files=("${SCHEMA_DIR}"/*.sql)

if (( ${#files[@]} == 0 )); then
  printf '[schema] Nenhum arquivo .sql encontrado em %s.\n' "$SCHEMA_DIR"
  exit 0
fi

for file in "${files[@]}"; do
  printf '[schema] Executando %s como %s.\n' "$(basename "$file")" "$DB_SCHEMA_USER"

  sqlplus -s -L "${DB_SCHEMA_USER}/\"${SCHEMA_PASSWORD}\"@//localhost:1521/FREEPDB1" <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON
SET VERIFY OFF
DEFINE DATA_TABLESPACE = ${DB_DATA_TABLESPACE}
DEFINE INDEX_TABLESPACE = ${DB_INDEX_TABLESPACE}
@${file}
EXIT
SQL
done
