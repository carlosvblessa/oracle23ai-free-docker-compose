#!/usr/bin/env bash
set -Eeuo pipefail

SCHEMA_DIR=/project/schema

if [[ ! -r /run/secrets/db_schema_password ]]; then
  printf '[schema] Secret ausente ou ilegível: /run/secrets/db_schema_password\n' >&2
  exit 1
fi

SCHEMA_PASSWORD="$(tr -d '\r\n' < /run/secrets/db_schema_password)"

shopt -s nullglob
files=("${SCHEMA_DIR}"/*.sql)

if (( ${#files[@]} == 0 )); then
  printf '[schema] Nenhum arquivo .sql encontrado em %s.\n' "$SCHEMA_DIR"
  exit 0
fi

for file in "${files[@]}"; do
  if [[ ! -r "$file" ]]; then
    printf '[schema] Arquivo SQL ausente ou ilegível: %s\n' "$file" >&2
    exit 1
  fi

  printf '[schema] Executando %s como %s.\n' "$(basename "$file")" "$DB_SCHEMA_USER"

  sqlplus_output="$(mktemp)"
  chmod 600 "$sqlplus_output"
  trap 'rm -f -- "$sqlplus_output"' EXIT

  set +e
  sqlplus -s -L "${DB_SCHEMA_USER}/\"${SCHEMA_PASSWORD}\"@//localhost:1521/FREEPDB1" 2>&1 <<SQL | tee "$sqlplus_output"
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON
SET VERIFY OFF
SET SQLBLANKLINES ON
DEFINE DATA_TABLESPACE = ${DB_DATA_TABLESPACE}
DEFINE INDEX_TABLESPACE = ${DB_INDEX_TABLESPACE}
@${file}
EXIT SUCCESS
SQL

  pipeline_status=("${PIPESTATUS[@]}")
  set -e

  if (( pipeline_status[0] != 0 )); then
    printf '[schema] SQL*Plus terminou com código %d ao executar %s.\n' \
      "${pipeline_status[0]}" "$(basename "$file")" >&2
    exit "${pipeline_status[0]}"
  fi

  if (( pipeline_status[1] != 0 )); then
    printf '[schema] Falha ao registrar a saída de %s.\n' "$(basename "$file")" >&2
    exit "${pipeline_status[1]}"
  fi

  if grep -Eq '^SP2-[0-9]+:' "$sqlplus_output"; then
    printf '[schema] Erro interno do SQL*Plus detectado em %s.\n' "$(basename "$file")" >&2
    exit 1
  fi

  rm -f -- "$sqlplus_output"
  trap - EXIT
done

printf '[schema] Todos os arquivos SQL foram executados com sucesso.\n'
