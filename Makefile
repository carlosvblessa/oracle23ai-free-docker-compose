SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# A imagem oficial exige ORACLE_PWD como variável de ambiente. Esta expressão
# lê o arquivo protegido apenas no momento em que o Compose é executado.
COMPOSE = ORACLE_PWD="$$(tr -d '\r\n' < secrets/oracle_password.txt)" docker compose

.PHONY: help init secrets access login config pull up logs ps status version provision \
        adopt-provisioned verify stop down destroy sql-sys sql-system sql-admin sql-owner \
        sql-app apply-schema refresh-grants backup

help:
	@printf '%s\n' \
	  'make init            Copia .env.example e gera os secrets' \
	  'make access          Libera via ACL a leitura necessária no container' \
	  'make login           Login opcional no registry, somente se o pull exigir' \
	  'make config          Valida silenciosamente o Compose' \
	  'make pull            Baixa a imagem pública oficial da Oracle' \
	  'make up              Inicia o banco em segundo plano' \
	  'make provision       Aguarda o banco e cria usuários, tablespaces e objetos' \
	  'make adopt-provisioned  Adota, após validar, um volume legado já preparado' \
	  'make verify          Valida usuários, tablespaces, objetos e role' \
	  'make logs            Acompanha os logs do Oracle' \
	  'make status          Mostra o container e seu healthcheck' \
	  'make version         Exibe a versão efetiva do banco' \
	  'make sql-sys         Abre SQL*Plus como SYSDBA' \
	  'make sql-system      Abre SQL*Plus como SYSTEM no FREEPDB1' \
	  'make sql-admin       Abre como administrador local' \
	  'make sql-owner       Abre como proprietário do esquema' \
	  'make sql-app         Abre como usuário da aplicação' \
	  'make apply-schema    Executa os arquivos db/schema/*.sql' \
	  'make refresh-grants  Reaplica grants nos objetos do esquema' \
	  'make backup          Exporta o esquema com Data Pump' \
	  'make down            Remove o container, preservando os dados' \
	  'make destroy         Remove container E volume de dados'

init:
	@test -f .env || cp .env.example .env
	@./scripts/generate-secrets.sh
	@./scripts/configure-container-access.sh
	@mkdir -p backups
	@printf '\nEdite .env e execute: make config && make pull && make up && make provision\n'

secrets:
	@./scripts/generate-secrets.sh
	@./scripts/configure-container-access.sh

access:
	@./scripts/configure-container-access.sh

login:
	@printf 'Login opcional: use somente se o registry responder com erro de autenticação.\n'
	@docker login container-registry.oracle.com

config:
	@$(COMPOSE) config --quiet
	@printf 'Configuração Compose válida.\n'

pull:
	@$(COMPOSE) pull oracle

up:
	@$(COMPOSE) up -d
	@$(COMPOSE) ps

provision:
	@./scripts/provision.sh

adopt-provisioned:
	@./scripts/provision.sh --adopt

verify: access
	@$(COMPOSE) exec -T oracle bash /project/setup/004-verify.sh

logs:
	@$(COMPOSE) logs -f oracle

ps:
	@$(COMPOSE) ps

status:
	@$(COMPOSE) ps
	@container_id="$$($(COMPOSE) ps -q oracle)"; \
	  test -n "$$container_id"; \
	  docker inspect --format='health={{if .State.Health}}{{.State.Health.Status}}{{else}}não definido{{end}} status={{.State.Status}}' "$$container_id"

version:
	@printf '%s\n' \
	  'SET HEADING OFF' \
	  'SET FEEDBACK OFF' \
	  'SET PAGESIZE 0' \
	  'SELECT banner_full FROM v$$version;' \
	  'EXIT;' | $(COMPOSE) exec -T oracle sqlplus -s "/ as sysdba"

stop:
	@$(COMPOSE) stop

down:
	@$(COMPOSE) down --remove-orphans

destroy:
	@printf 'ATENÇÃO: isto removerá definitivamente o volume do banco.\n'
	@$(COMPOSE) down -v --remove-orphans

sql-sys:
	@$(COMPOSE) exec oracle bash -lc 'sqlplus -L / as sysdba'

sql-system:
	@$(COMPOSE) exec oracle bash -lc 'sqlplus -L "system/\"$${ORACLE_PWD}\"@//localhost:1521/FREEPDB1"'

sql-admin: access
	@$(COMPOSE) exec oracle bash -lc 'sqlplus -L "$${DB_ADMIN_USER}/\"$$(cat /run/secrets/db_admin_password)\"@//localhost:1521/FREEPDB1"'

sql-owner: access
	@$(COMPOSE) exec oracle bash -lc 'sqlplus -L "$${DB_SCHEMA_USER}/\"$$(cat /run/secrets/db_schema_password)\"@//localhost:1521/FREEPDB1"'

sql-app: access
	@$(COMPOSE) exec oracle bash -lc 'sqlplus -L "$${DB_RUNTIME_USER}/\"$$(cat /run/secrets/db_runtime_password)\"@//localhost:1521/FREEPDB1"'

apply-schema: access
	@$(COMPOSE) exec -T oracle bash /project/setup/002-run-schema.sh
	@$(COMPOSE) exec -T oracle bash /project/setup/003-runtime-grants.sh

refresh-grants: access
	@$(COMPOSE) exec -T oracle bash /project/setup/003-runtime-grants.sh

backup:
	@./scripts/export-schema.sh
