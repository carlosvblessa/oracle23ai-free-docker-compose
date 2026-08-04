#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

log() {
  printf '[provision] %s\n' "$*"
}

fail() {
  printf '[provision] ERRO: %s\n' "$*" >&2
  exit 1
}

# Não depende do ambiente de um container criado por uma versão anterior do
# Compose: cada exec do provisionamento recebe explicitamente o charset Oracle.
compose_exec() {
  docker compose exec -T -e NLS_LANG=.AL32UTF8 "$@"
}

MODE=provision
if (( $# > 1 )); then
  fail 'Uso: scripts/provision.sh [--adopt]'
fi

if [[ "${1:-}" == "--adopt" ]]; then
  MODE=adopt
elif (( $# == 1 )); then
  fail 'Uso: scripts/provision.sh [--adopt]'
fi

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

ORACLE_HEALTH_TIMEOUT="${ORACLE_HEALTH_TIMEOUT:-900}"
[[ "$ORACLE_HEALTH_TIMEOUT" =~ ^[0-9]+$ ]] \
  || fail "ORACLE_HEALTH_TIMEOUT deve ser numérico: ${ORACLE_HEALTH_TIMEOUT}"

ORACLE_PASSWORD_FILE=secrets/oracle_password.txt
[[ -r "$ORACLE_PASSWORD_FILE" ]] \
  || fail "Secret ausente ou ilegível: ${ORACLE_PASSWORD_FILE}"

export ORACLE_PWD
ORACLE_PWD="$(tr -d '\r\n' < "$ORACLE_PASSWORD_FILE")"

./scripts/configure-container-access.sh

container_id="$(docker compose ps -q oracle)"
[[ -n "$container_id" ]] || fail 'Container Oracle não encontrado. Execute make up.'

log "Aguardando o healthcheck por até ${ORACLE_HEALTH_TIMEOUT}s."
deadline=$((SECONDS + ORACLE_HEALTH_TIMEOUT))

while true; do
  container_status="$(docker inspect --format='{{.State.Status}}' "$container_id")"
  health_status="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")"

  if [[ "$container_status" == "running" && "$health_status" == "healthy" ]]; then
    break
  fi

  if [[ "$container_status" == "exited" || "$container_status" == "dead" ]]; then
    docker compose logs --tail=100 oracle >&2
    fail "Container terminou com status ${container_status}."
  fi

  if (( SECONDS >= deadline )); then
    docker compose logs --tail=100 oracle >&2
    fail "Healthcheck não ficou healthy dentro de ${ORACLE_HEALTH_TIMEOUT}s."
  fi

  sleep 2
done

log 'Container saudável.'

compose_exec oracle bash -lc '
  set -Eeuo pipefail
  required=(
    /run/secrets/db_admin_password
    /run/secrets/db_schema_password
    /run/secrets/db_runtime_password
    /project/setup/001-bootstrap.sh
    /project/setup/002-run-schema.sh
    /project/setup/003-runtime-grants.sh
    /project/setup/004-verify.sh
  )

  for file in "${required[@]}"; do
    [[ -r "$file" ]] || {
      printf "[provision] Arquivo ausente ou ilegível no container: %s\n" "$file" >&2
      exit 1
    }
  done

  while IFS= read -r -d "" file; do
    [[ -r "$file" ]] || {
      printf "[provision] DDL ilegível no container: %s\n" "$file" >&2
      exit 1
    }
  done < <(find /project/schema -maxdepth 1 -type f -name "*.sql" -print0)

  [[ -w /opt/oracle/oradata ]] || {
    printf "[provision] Volume /opt/oracle/oradata não permite gravar o marcador.\n" >&2
    exit 1
  }
'

PROVISION_MARKER=/opt/oracle/oradata/.oracle23ai-project-provisioned
if compose_exec oracle test -f "$PROVISION_MARKER"; then
  log 'Provisionamento já concluído neste volume; nenhuma alteração reaplicada.'
  compose_exec oracle bash /project/setup/004-verify.sh
  log 'Para novos DDLs idempotentes, use make apply-schema.'
  exit 0
fi

if [[ "$MODE" == "adopt" ]]; then
  log 'Validando provisionamento legado antes de criar o marcador.'
  compose_exec oracle bash /project/setup/004-verify.sh
  compose_exec oracle touch "$PROVISION_MARKER"
  log 'Volume legado validado e adotado pelo fluxo explícito.'
  exit 0
fi

compose_exec oracle bash /project/setup/001-bootstrap.sh

existing_object_count="$({
  compose_exec oracle \
    bash /project/setup/004-verify.sh --object-count
} | tr -d '[:space:]')"

[[ "$existing_object_count" =~ ^[0-9]+$ ]] \
  || fail "Não foi possível determinar a quantidade de objetos existentes: ${existing_object_count}"

if (( existing_object_count > 0 )); then
  fail "O owner já possui ${existing_object_count} objeto(s), mas o volume não tem marcador. O DDL não foi reaplicado. Valide com make verify e, se este for um volume legado completo, execute make adopt-provisioned."
fi

compose_exec oracle bash /project/setup/002-run-schema.sh
compose_exec oracle bash /project/setup/003-runtime-grants.sh
compose_exec oracle bash /project/setup/004-verify.sh
compose_exec oracle touch "$PROVISION_MARKER"

log 'Provisionamento concluído e volume marcado.'
