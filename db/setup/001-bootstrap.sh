#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[bootstrap] %s\n' "$*"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    log "Variável obrigatória ausente: ${name}"
    exit 1
  fi
}

validate_identifier() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[A-Z][A-Z0-9_]{1,29}$ ]]; then
    log "${name} deve ter 2 a 30 caracteres, começar por letra e conter apenas A-Z, 0-9 e _. Valor: ${value}"
    exit 1
  fi
}

read_secret() {
  local file="$1"
  if [[ ! -r "$file" ]]; then
    log "Secret não encontrado ou ilegível: ${file}"
    exit 1
  fi
  tr -d '\r\n' < "$file"
}

validate_password() {
  local name="$1"
  local value="$2"

  if (( ${#value} < 12 )); then
    log "${name} deve possuir pelo menos 12 caracteres."
    exit 1
  fi

  if [[ ! "$value" =~ ^[A-Za-z0-9_#@!%.=-]+$ ]]; then
    log "${name} contém caractere não permitido. Use letras, números e _ # @ ! % . = -"
    exit 1
  fi

  [[ "$value" =~ [A-Z] ]] || { log "${name} precisa de letra maiúscula."; exit 1; }
  [[ "$value" =~ [a-z] ]] || { log "${name} precisa de letra minúscula."; exit 1; }
  [[ "$value" =~ [0-9] ]] || { log "${name} precisa de número."; exit 1; }
}

for var in \
  ORACLE_CDB_NAME \
  ORACLE_PDB_NAME \
  DB_ADMIN_USER \
  DB_SCHEMA_USER \
  DB_RUNTIME_USER \
  DB_RUNTIME_ROLE \
  DB_DATA_TABLESPACE \
  DB_INDEX_TABLESPACE; do
  require_env "$var"
  validate_identifier "$var" "${!var}"
done

if [[ "$ORACLE_CDB_NAME" != "FREE" || "$ORACLE_PDB_NAME" != "FREEPDB1" ]]; then
  log 'A imagem oficial Oracle Database Free exige CDB FREE e PDB FREEPDB1.'
  exit 1
fi

DB_ADMIN_PASSWORD="$(read_secret /run/secrets/db_admin_password)"
DB_SCHEMA_PASSWORD="$(read_secret /run/secrets/db_schema_password)"
DB_RUNTIME_PASSWORD="$(read_secret /run/secrets/db_runtime_password)"

validate_password DB_ADMIN_PASSWORD "$DB_ADMIN_PASSWORD"
validate_password DB_SCHEMA_PASSWORD "$DB_SCHEMA_PASSWORD"
validate_password DB_RUNTIME_PASSWORD "$DB_RUNTIME_PASSWORD"

DATAFILE_DIR="/opt/oracle/oradata/FREE/FREEPDB1"
DATAFILE_NAME="$(printf '%s' "$DB_DATA_TABLESPACE" | tr '[:upper:]' '[:lower:]')01.dbf"
INDEXFILE_NAME="$(printf '%s' "$DB_INDEX_TABLESPACE" | tr '[:upper:]' '[:lower:]')01.dbf"

if [[ ! -d "$DATAFILE_DIR" ]]; then
  log "Diretório esperado dos datafiles não existe: ${DATAFILE_DIR}"
  exit 1
fi

log "Configurando usuários e tablespaces no PDB ${ORACLE_PDB_NAME}."

sqlplus -s / as sysdba <<SQL
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON
SET VERIFY OFF

ALTER SESSION SET CONTAINER=${ORACLE_PDB_NAME};

DECLARE
  v_count PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM DBA_TABLESPACES
   WHERE TABLESPACE_NAME = '${DB_DATA_TABLESPACE}';

  IF v_count = 0 THEN
    EXECUTE IMMEDIATE
      'CREATE BIGFILE TABLESPACE ${DB_DATA_TABLESPACE} '
      || 'DATAFILE ''${DATAFILE_DIR}/${DATAFILE_NAME}'' SIZE 256M '
      || 'AUTOEXTEND ON NEXT 64M MAXSIZE 8G '
      || 'EXTENT MANAGEMENT LOCAL SEGMENT SPACE MANAGEMENT AUTO';
  END IF;
END;
/

DECLARE
  v_count PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM DBA_TABLESPACES
   WHERE TABLESPACE_NAME = '${DB_INDEX_TABLESPACE}';

  IF v_count = 0 THEN
    EXECUTE IMMEDIATE
      'CREATE BIGFILE TABLESPACE ${DB_INDEX_TABLESPACE} '
      || 'DATAFILE ''${DATAFILE_DIR}/${INDEXFILE_NAME}'' SIZE 128M '
      || 'AUTOEXTEND ON NEXT 64M MAXSIZE 4G '
      || 'EXTENT MANAGEMENT LOCAL SEGMENT SPACE MANAGEMENT AUTO';
  END IF;
END;
/

DECLARE
  v_count PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM DBA_USERS WHERE USERNAME = '${DB_ADMIN_USER}';
  IF v_count = 0 THEN
    EXECUTE IMMEDIATE
      'CREATE USER ${DB_ADMIN_USER} IDENTIFIED BY "${DB_ADMIN_PASSWORD}" '
      || 'DEFAULT TABLESPACE USERS TEMPORARY TABLESPACE TEMP';
  ELSE
    EXECUTE IMMEDIATE
      'ALTER USER ${DB_ADMIN_USER} IDENTIFIED BY "${DB_ADMIN_PASSWORD}" ACCOUNT UNLOCK';
  END IF;
END;
/

GRANT CREATE SESSION, DBA TO ${DB_ADMIN_USER};

DECLARE
  v_count PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM DBA_USERS WHERE USERNAME = '${DB_SCHEMA_USER}';
  IF v_count = 0 THEN
    EXECUTE IMMEDIATE
      'CREATE USER ${DB_SCHEMA_USER} IDENTIFIED BY "${DB_SCHEMA_PASSWORD}" '
      || 'DEFAULT TABLESPACE ${DB_DATA_TABLESPACE} '
      || 'TEMPORARY TABLESPACE TEMP '
      || 'QUOTA UNLIMITED ON ${DB_DATA_TABLESPACE} '
      || 'QUOTA UNLIMITED ON ${DB_INDEX_TABLESPACE}';
  ELSE
    EXECUTE IMMEDIATE
      'ALTER USER ${DB_SCHEMA_USER} IDENTIFIED BY "${DB_SCHEMA_PASSWORD}" ACCOUNT UNLOCK';
  END IF;
END;
/

GRANT CREATE SESSION,
      CREATE TABLE,
      CREATE VIEW,
      CREATE MATERIALIZED VIEW,
      CREATE SEQUENCE,
      CREATE PROCEDURE,
      CREATE TRIGGER,
      CREATE TYPE,
      CREATE SYNONYM,
      CREATE JOB
TO ${DB_SCHEMA_USER};

DECLARE
  v_count PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM DBA_ROLES WHERE ROLE = '${DB_RUNTIME_ROLE}';
  IF v_count = 0 THEN
    EXECUTE IMMEDIATE 'CREATE ROLE ${DB_RUNTIME_ROLE}';
  END IF;
END;
/

DECLARE
  v_count PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM DBA_USERS WHERE USERNAME = '${DB_RUNTIME_USER}';
  IF v_count = 0 THEN
    EXECUTE IMMEDIATE
      'CREATE USER ${DB_RUNTIME_USER} IDENTIFIED BY "${DB_RUNTIME_PASSWORD}" '
      || 'DEFAULT TABLESPACE USERS TEMPORARY TABLESPACE TEMP';
  ELSE
    EXECUTE IMMEDIATE
      'ALTER USER ${DB_RUNTIME_USER} IDENTIFIED BY "${DB_RUNTIME_PASSWORD}" ACCOUNT UNLOCK';
  END IF;
END;
/

GRANT CREATE SESSION TO ${DB_RUNTIME_USER};
GRANT ${DB_RUNTIME_ROLE} TO ${DB_RUNTIME_USER};

PROMPT === Configuração básica concluída ===
SELECT SYS_CONTEXT('USERENV', 'CON_NAME') AS PDB_ATUAL FROM DUAL;
SELECT USERNAME, ACCOUNT_STATUS, DEFAULT_TABLESPACE
  FROM DBA_USERS
 WHERE USERNAME IN ('${DB_ADMIN_USER}', '${DB_SCHEMA_USER}', '${DB_RUNTIME_USER}')
 ORDER BY USERNAME;

EXIT SUCCESS
SQL

log 'Bootstrap concluído.'
