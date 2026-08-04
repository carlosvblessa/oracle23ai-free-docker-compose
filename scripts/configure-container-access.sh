#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

log() {
  printf '[access] %s\n' "$*"
}

fail() {
  printf '[access] ERRO: %s\n' "$*" >&2
  exit 1
}

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

ORACLE_CONTAINER_UID="${ORACLE_CONTAINER_UID:-54321}"
[[ "$ORACLE_CONTAINER_UID" =~ ^[0-9]+$ ]] \
  || fail "ORACLE_CONTAINER_UID deve ser numérico: ${ORACLE_CONTAINER_UID}"

if ! command -v setfacl >/dev/null 2>&1; then
  fail 'setfacl não está instalado. Ubuntu/Debian: sudo apt install acl. RHEL/Oracle Linux/Fedora: sudo dnf install acl.'
fi

shopt -s nullglob
secret_files=(secrets/*.txt)
schema_files=(db/schema/*.sql)
setup_files=(db/setup/*.sh)

(( ${#secret_files[@]} > 0 )) \
  || fail 'Nenhum secret encontrado. Execute make init ou scripts/prepare-target.sh.'

# Os secrets e DDLs privados continuam sem leitura para "other". A ACL libera
# somente o UID fixo do usuário oracle na imagem oficial.
setfacl -m "u:${ORACLE_CONTAINER_UID}:rx" db/setup db/schema
setfacl -m "u:${ORACLE_CONTAINER_UID}:r" "${secret_files[@]}"

if (( ${#setup_files[@]} > 0 )); then
  setfacl -m "u:${ORACLE_CONTAINER_UID}:rx" "${setup_files[@]}"
fi

if (( ${#schema_files[@]} > 0 )); then
  setfacl -m "u:${ORACLE_CONTAINER_UID}:r" "${schema_files[@]}"
fi

log "Leitura concedida ao UID ${ORACLE_CONTAINER_UID} nos secrets e artefatos de provisionamento."
