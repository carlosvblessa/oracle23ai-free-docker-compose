#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="${ROOT_DIR}/secrets"

mkdir -p "$SECRETS_DIR"
umask 077

generate_password() {
  printf 'Aa1#%s\n' "$(openssl rand -hex 14)"
}

create_secret() {
  local file="$1"
  if [[ -e "$file" || -L "$file" ]]; then
    [[ -f "$file" && ! -L "$file" ]] \
      || { printf 'ERRO: secret não é um arquivo regular: %s\n' "$file" >&2; exit 1; }
    chmod 600 "$file"
    printf 'Mantido: %s\n' "$file"
    return
  fi
  generate_password > "$file"
  chmod 600 "$file"
  printf 'Criado: %s\n' "$file"
}

create_secret "${SECRETS_DIR}/oracle_password.txt"
create_secret "${SECRETS_DIR}/db_admin_password.txt"
create_secret "${SECRETS_DIR}/db_schema_password.txt"
create_secret "${SECRETS_DIR}/db_runtime_password.txt"

printf '\nSecrets mantidos com permissão 600. Não os adicione ao Git.\n'
