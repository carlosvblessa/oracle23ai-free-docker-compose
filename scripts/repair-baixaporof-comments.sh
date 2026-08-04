#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SQL_FILE=local/ddl/001_ods_baixaporof_cadastro.sql
ORACLE_PASSWORD_FILE=secrets/oracle_password.txt
START_PATTERN='^COMMENT ON TABLE ADMODS001\.ODS_BAIXAPOROF_CADASTRO IS'

fail() {
  printf '[repair-comments] ERRO: %s\n' "$*" >&2
  exit 1
}

[[ -r "$SQL_FILE" ]] || fail "Arquivo ausente ou ilegível: ${SQL_FILE}"
[[ -r "$ORACLE_PASSWORD_FILE" ]] \
  || fail "Secret ausente ou ilegível: ${ORACLE_PASSWORD_FILE}"

comments_sql="$(mktemp)"
chmod 600 "$comments_sql"
trap 'rm -f -- "$comments_sql"' EXIT

# Extrai somente a cauda iniciada pelo primeiro comentário da tabela. O DDL
# completo nunca é enviado ao banco existente.
sed -n "/${START_PATTERN}/,\$p" "$SQL_FILE" > "$comments_sql"
[[ -s "$comments_sql" ]] \
  || fail 'Início da seção COMMENT ON não encontrado; nenhuma instrução executada.'

# Defesa adicional: só aceita COMMENT ON nos dois objetos conhecidos e rejeita
# comandos SQL, PL/SQL ou SQL*Plus que poderiam alterar algo além dos comentários.
awk '
  function reject(message) {
    print "[repair-comments] ERRO: " message > "/dev/stderr"
    invalid = 1
  }

  {
    upper = toupper($0)

    if (upper ~ /^[[:space:]]*COMMENT[[:space:]]+ON([[:space:]]|$)/) {
      comments++
      table_comment = "^[[:space:]]*COMMENT[[:space:]]+ON[[:space:]]+TABLE[[:space:]]+ADMODS001[.](ODS_BAIXAPOROF_CADASTRO|ODS_VW_BAIXAPOROFICIO)[[:space:]]+IS([[:space:]]|$)"
      column_comment = "^[[:space:]]*COMMENT[[:space:]]+ON[[:space:]]+COLUMN[[:space:]]+ADMODS001[.](ODS_BAIXAPOROF_CADASTRO|ODS_VW_BAIXAPOROFICIO)[.][A-Z0-9_$#]+[[:space:]]+IS([[:space:]]|$)"

      if (upper !~ table_comment && upper !~ column_comment) {
        reject("COMMENT ON fora da allowlist na linha " NR ".")
      }
      next
    }

    if (upper ~ /^[[:space:]]*(CREATE|ALTER|DROP|TRUNCATE|INSERT|UPDATE|DELETE|MERGE|GRANT|REVOKE|BEGIN|DECLARE|CALL|EXECUTE|COMMIT|ROLLBACK|HOST|SPOOL|START|CONNECT|WHENEVER|SET|DEFINE|ACCEPT|VARIABLE|PROMPT|EXIT)([[:space:];]|$)/ ||
        upper ~ /^[[:space:]]*(@@?|!|\/)[[:space:]]*/) {
      reject("comando não permitido na linha " NR ".")
    }
  }

  END {
    if (comments == 0) {
      reject("nenhum COMMENT ON encontrado.")
    }
    exit invalid ? 1 : 0
  }
' "$comments_sql" || fail 'A seção extraída contém instruções não permitidas; nada foi executado.'

export ORACLE_PWD
ORACLE_PWD="$(tr -d '\r\n' < "$ORACLE_PASSWORD_FILE")"

{
  printf '%s\n' \
    'WHENEVER OSERROR EXIT FAILURE' \
    'WHENEVER SQLERROR EXIT SQL.SQLCODE' \
    'ALTER SESSION SET CONTAINER=FREEPDB1;'
  sed -n '1,$p' "$comments_sql"
  printf '%s\n' 'EXIT SUCCESS'
} | docker compose exec -T \
      -e NLS_LANG=.AL32UTF8 \
      oracle \
      sqlplus -s "/ as sysdba"

printf '[repair-comments] Comentários reaplicados com NLS_LANG=.AL32UTF8.\n'
