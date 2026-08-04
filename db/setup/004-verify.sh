#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == "--object-count" ]]; then
  sqlplus -s / as sysdba <<SQL
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SET VERIFY OFF

ALTER SESSION SET CONTAINER=FREEPDB1;
SELECT COUNT(*) FROM DBA_OBJECTS WHERE OWNER = '${DB_SCHEMA_USER}';
EXIT SUCCESS
SQL
  exit 0
fi

if (( $# > 0 )); then
  printf '[verify] Opção inválida. Uso: 004-verify.sh [--object-count]\n' >&2
  exit 2
fi

shopt -s nullglob
schema_files=(/project/schema/*.sql)

if (( ${#schema_files[@]} > 0 )); then
  REQUIRE_SCHEMA_OBJECTS=1
else
  REQUIRE_SCHEMA_OBJECTS=0
fi

sqlplus -s / as sysdba <<SQL
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET HEADING ON
SET FEEDBACK ON
SET PAGESIZE 100
SET LINESIZE 220
SET VERIFY OFF

ALTER SESSION SET CONTAINER=FREEPDB1;

DECLARE
  v_count PLS_INTEGER;

  PROCEDURE assert_count(p_sql VARCHAR2, p_expected PLS_INTEGER, p_message VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql INTO v_count;
    IF v_count != p_expected THEN
      RAISE_APPLICATION_ERROR(-20001, p_message || ' Encontrado: ' || v_count);
    END IF;
  END;
BEGIN
  assert_count(
    'SELECT COUNT(*) FROM DBA_USERS WHERE USERNAME IN (''${DB_ADMIN_USER}'', ''${DB_SCHEMA_USER}'', ''${DB_RUNTIME_USER}'')',
    3,
    'Usuários esperados não encontrados.'
  );

  assert_count(
    'SELECT COUNT(*) FROM DBA_TABLESPACES WHERE STATUS = ''ONLINE'' AND TABLESPACE_NAME IN (''${DB_DATA_TABLESPACE}'', ''${DB_INDEX_TABLESPACE}'')',
    2,
    'Tablespaces esperados não estão ONLINE.'
  );

  assert_count(
    'SELECT COUNT(*) FROM DBA_ROLE_PRIVS WHERE GRANTEE = ''${DB_ADMIN_USER}'' AND GRANTED_ROLE = ''DBA''',
    1,
    'Role DBA ausente no usuário administrativo.'
  );

  assert_count(
    'SELECT COUNT(*) FROM DBA_ROLE_PRIVS WHERE GRANTEE = ''${DB_RUNTIME_USER}'' AND GRANTED_ROLE = ''${DB_RUNTIME_ROLE}''',
    1,
    'Role de runtime/carga não concedida ao usuário.'
  );

  IF ${REQUIRE_SCHEMA_OBJECTS} = 1 THEN
    SELECT COUNT(*) INTO v_count
      FROM DBA_OBJECTS
     WHERE OWNER = '${DB_SCHEMA_USER}';

    IF v_count = 0 THEN
      RAISE_APPLICATION_ERROR(-20002, 'Há DDLs em /project/schema, mas nenhum objeto foi criado para ${DB_SCHEMA_USER}.');
    END IF;
  END IF;
END;
/

PROMPT === Usuários ===
SELECT USERNAME, ACCOUNT_STATUS, DEFAULT_TABLESPACE
  FROM DBA_USERS
 WHERE USERNAME IN ('${DB_ADMIN_USER}', '${DB_SCHEMA_USER}', '${DB_RUNTIME_USER}')
 ORDER BY USERNAME;

PROMPT === Tablespaces ===
SELECT TABLESPACE_NAME, STATUS, CONTENTS
  FROM DBA_TABLESPACES
 WHERE TABLESPACE_NAME IN ('${DB_DATA_TABLESPACE}', '${DB_INDEX_TABLESPACE}')
 ORDER BY TABLESPACE_NAME;

PROMPT === Objetos do owner ===
SELECT OBJECT_TYPE, COUNT(*) AS QUANTIDADE
  FROM DBA_OBJECTS
 WHERE OWNER = '${DB_SCHEMA_USER}'
 GROUP BY OBJECT_TYPE
 ORDER BY OBJECT_TYPE;

PROMPT === Role do usuário de carga/runtime ===
SELECT GRANTEE, GRANTED_ROLE
  FROM DBA_ROLE_PRIVS
 WHERE GRANTEE = '${DB_RUNTIME_USER}'
   AND GRANTED_ROLE = '${DB_RUNTIME_ROLE}';

EXIT SUCCESS
SQL

printf '[verify] Provisionamento validado com sucesso.\n'
