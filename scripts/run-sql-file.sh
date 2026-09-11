#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

log() {
  printf '[sql-file] %s\n' "$*"
}

fail() {
  printf '[sql-file] ERRO: %s\n' "$*" >&2
  exit 1
}

SQL_FILE="${1:-}"

[[ -n "$SQL_FILE" ]] \
  || fail 'Informe SQL_FILE. Exemplo: make sql-app-file SQL_FILE=local/sql/consulta.sql'
[[ "$SQL_FILE" == *.sql ]] \
  || fail "O arquivo deve possuir extensão .sql: ${SQL_FILE}"
[[ -f "$SQL_FILE" ]] \
  || fail "Arquivo não encontrado: ${SQL_FILE}"
[[ -r "$SQL_FILE" ]] \
  || fail "Arquivo ilegível: ${SQL_FILE}"

./scripts/configure-container-access.sh

[[ -r secrets/oracle_password.txt ]] \
  || fail 'Secret ausente ou ilegível: secrets/oracle_password.txt'

export ORACLE_PWD
ORACLE_PWD="$(tr -d '\r\n' < secrets/oracle_password.txt)"

sqlplus_output="$(mktemp)"
chmod 600 "$sqlplus_output"
trap 'rm -f -- "$sqlplus_output"' EXIT

log "Executando ${SQL_FILE} como usuário da aplicação."

set +e
{
  printf '%s\n' \
    'WHENEVER OSERROR EXIT FAILURE' \
    'WHENEVER SQLERROR EXIT SQL.SQLCODE' \
    'SET SQLBLANKLINES ON'
  cat -- "$SQL_FILE"
} | docker compose exec -T oracle bash -lc \
  'if [[ ! -r /run/secrets/db_runtime_password ]]; then printf "[sql-file] ERRO: secret /run/secrets/db_runtime_password ausente ou ilegível.\n" >&2; exit 1; fi; exec sqlplus -s -L "${DB_RUNTIME_USER}/\"$(cat /run/secrets/db_runtime_password)\"@//localhost:1521/FREEPDB1"' \
  2>&1 | tee "$sqlplus_output"
pipeline_status=("${PIPESTATUS[@]}")
set -e

if (( pipeline_status[1] != 0 )); then
  fail "SQL*Plus terminou com código ${pipeline_status[1]} ao executar ${SQL_FILE}."
fi

if (( pipeline_status[2] != 0 )); then
  fail "Falha ao registrar a saída de ${SQL_FILE}."
fi

if (( pipeline_status[0] != 0 )); then
  fail "Falha ao ler o arquivo SQL: ${SQL_FILE}"
fi

if grep -Eq '^SP2-[0-9]+:' "$sqlplus_output"; then
  fail "Erro interno do SQL*Plus detectado em ${SQL_FILE}."
fi

log 'Execução concluída com sucesso.'
