#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DDL="${ROOT_DIR}/db/schema/010_target_baseline.sql"
ENV_FILE="${ROOT_DIR}/.env"
FORCE=false

usage() {
  cat <<'EOF'
Uso:
  TARGET_SCHEMA_USER=<owner> \
  TARGET_LOADER_USER=<loader> \
  TARGET_LOADER_ROLE=<role> \
  TARGET_DATA_TABLESPACE=<tablespace_dados> \
  TARGET_INDEX_TABLESPACE=<tablespace_indices> \
  ./scripts/prepare-target.sh [--force] /caminho/ddl_origem.sql

O script prepara somente o clone local da máquina destino. Ele:
  - cria ou atualiza o .env local;
  - gera os secrets locais, se ainda não existirem;
  - deriva um DDL privado em db/schema/010_target_baseline.sql;
  - preserva o DDL recebido sem modificá-lo.

Use --force somente para substituir um DDL destino já gerado.
EOF
}

log() {
  printf '[prepare-target] %s\n' "$*"
}

fail() {
  printf '[prepare-target] ERRO: %s\n' "$*" >&2
  exit 1
}

validate_identifier() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[A-Z][A-Z0-9_]{1,29}$ ]]; then
    fail "${name} deve ter 2 a 30 caracteres e usar somente A-Z, 0-9 e _."
  fi
}

set_env_value() {
  local key="$1"
  local value="$2"

  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*$|${key}=${value}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

if [[ "${1:-}" == "--force" ]]; then
  FORCE=true
  shift
fi

if (( $# != 1 )); then
  usage
  exit 2
fi

SOURCE_DDL="$1"
[[ -r "$SOURCE_DDL" ]] || fail "DDL não encontrado ou ilegível: ${SOURCE_DDL}"

for var in \
  TARGET_SCHEMA_USER \
  TARGET_LOADER_USER \
  TARGET_LOADER_ROLE \
  TARGET_DATA_TABLESPACE \
  TARGET_INDEX_TABLESPACE; do
  [[ -n "${!var:-}" ]] || fail "Variável obrigatória ausente: ${var}"
  validate_identifier "$var" "${!var}"
done

grep -Eq "^CREATE TABLE[[:space:]]+${TARGET_SCHEMA_USER}\." "$SOURCE_DDL" \
  || fail "O DDL não cria uma tabela qualificada pelo owner ${TARGET_SCHEMA_USER}."

TABLE_COUNT="$(grep -Ec '^CREATE TABLE[[:space:]]+' "$SOURCE_DDL" || true)"
INDEX_COUNT="$(grep -Ec '^CREATE (UNIQUE )?INDEX[[:space:]]+' "$SOURCE_DDL" || true)"
VIEW_COUNT="$(grep -Ec '^CREATE( OR REPLACE)? VIEW[[:space:]]+' "$SOURCE_DDL" || true)"

[[ "$TABLE_COUNT" == "1" ]] \
  || fail "Esperado exatamente 1 CREATE TABLE; encontrados: ${TABLE_COUNT}."
(( INDEX_COUNT > 0 )) || fail 'Nenhum CREATE INDEX encontrado no DDL.'
(( VIEW_COUNT > 0 )) || fail 'Nenhum CREATE VIEW encontrado no DDL.'

if awk '
  /^CREATE( OR REPLACE)? VIEW[[:space:]]+/ { after_view = 1; next }
  after_view && /^[[:space:]]*$/ { next }
  after_view {
    if ($0 ~ /^[[:space:]]*\(\)[[:space:]]*$/) bad = 1
    after_view = 0
  }
  END { exit bad ? 0 : 1 }
' "$SOURCE_DDL"; then
  fail 'A view possui uma lista de colunas vazia (). Remova os parênteses antes de continuar.'
fi

if [[ -e "$TARGET_DDL" && "$FORCE" != true ]]; then
  fail "O DDL destino já existe: ${TARGET_DDL}. Use --force para substituí-lo."
fi

TMP_DIR="$(mktemp -d)"
GENERATED_DDL="${TMP_DIR}/010_target_baseline.sql"

cleanup() {
  if [[ -f "$GENERATED_DDL" ]]; then
    rm -f -- "$GENERATED_DDL"
  fi
  rmdir -- "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

if ! awk '
  BEGIN {
    table_adjusted = 0
    indexes_adjusted = 0
    print "-- Gerado localmente por scripts/prepare-target.sh. Não versionar."
    print "-- O DDL de origem foi preservado sem alterações."
    print ""
  }

  !table_adjusted && /^[[:space:]]*\);[[:space:]]*$/ {
    print ") SEGMENT CREATION IMMEDIATE"
    print "  PCTFREE 0"
    print "  COMPRESS BASIC NOLOGGING"
    print "  TABLESPACE &&DATA_TABLESPACE;"
    table_adjusted = 1
    next
  }

  /^CREATE (UNIQUE )?INDEX[[:space:]]+/ {
    line = $0
    sub(/[[:space:]]*;[[:space:]]*$/, "", line)
    print line
    print "  PCTFREE 10 INITRANS 2 COMPUTE STATISTICS"
    print "  COMPRESS 1 NOLOGGING"
    print "  TABLESPACE &&INDEX_TABLESPACE;"
    indexes_adjusted++
    next
  }

  { print }

  END {
    if (!table_adjusted) {
      print "Não foi possível localizar o fechamento da tabela." > "/dev/stderr"
      exit 10
    }
    if (indexes_adjusted == 0) {
      print "Nenhum índice foi ajustado." > "/dev/stderr"
      exit 11
    }
  }
' "$SOURCE_DDL" > "$GENERATED_DDL"; then
  fail 'Falha ao gerar o DDL adaptado.'
fi

if [[ ! -f "$ENV_FILE" ]]; then
  cp "${ROOT_DIR}/.env.example" "$ENV_FILE"
  log 'Criado .env local a partir de .env.example.'
else
  BACKUP_ENV="${ROOT_DIR}/.env.backup.$(date +%Y%m%d_%H%M%S)"
  cp -p "$ENV_FILE" "$BACKUP_ENV"
  log "Backup do .env criado em ${BACKUP_ENV}."
fi

set_env_value DB_SCHEMA_USER "$TARGET_SCHEMA_USER"
set_env_value DB_RUNTIME_USER "$TARGET_LOADER_USER"
set_env_value DB_RUNTIME_ROLE "$TARGET_LOADER_ROLE"
set_env_value DB_DATA_TABLESPACE "$TARGET_DATA_TABLESPACE"
set_env_value DB_INDEX_TABLESPACE "$TARGET_INDEX_TABLESPACE"

"${ROOT_DIR}/scripts/generate-secrets.sh"
mv "$GENERATED_DDL" "$TARGET_DDL"

log "DDL privado gerado em ${TARGET_DDL}."
log "Owner: ${TARGET_SCHEMA_USER}"
log "Loader: ${TARGET_LOADER_USER} via role ${TARGET_LOADER_ROLE}"
log "Tablespaces: ${TARGET_DATA_TABLESPACE} / ${TARGET_INDEX_TABLESPACE}"
log 'Preparação concluída. Próximos passos: make config && make pull && make up'
