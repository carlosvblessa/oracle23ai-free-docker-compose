# Oracle Database 23ai Free oficial com Docker Compose

Ambiente reproduzível usando **somente a imagem oficial da Oracle** publicada
no Oracle Container Registry:

```text
container-registry.oracle.com/database/free:23.9.0.0
```

A versão foi fixada deliberadamente. A tag `latest` já pode apontar para a
linha 26ai e, portanto, não é adequada para reproduzir uma situação ocorrida
no Oracle 23c/23ai.

## Limitações assumidas da imagem oficial Free

A edição Free oficial possui nomes internos fixos:

| Item | Valor fixo |
|---|---|
| CDB / SID | `FREE` |
| PDB | `FREEPDB1` |
| Service name | `FREEPDB1` |

O nome funcional do laboratório aparece no projeto Compose, container, volume,
rede, usuários, schemas e tablespaces; o CDB e o PDB não são renomeados.

A imagem também recebe a senha de `SYS`, `SYSTEM` e `PDBADMIN` pela variável
`ORACLE_PWD`. Ela não oferece `ORACLE_PWD_FILE` para Docker Compose. Para não
registrar a senha no YAML ou no `.env`, o Makefile lê o arquivo protegido
`secrets/oracle_password.txt` e injeta a variável somente ao executar o
Compose. Ainda assim, administradores do host Docker podem vê-la com
`docker inspect`. As senhas dos usuários criados pelo projeto usam Docker
Secrets normalmente.

## Estrutura

```text
.
├── compose.yaml
├── .env.example
├── Makefile
├── db
│   ├── setup
│   │   ├── 001-bootstrap.sh
│   │   ├── 002-run-schema.sh
│   │   └── 003-runtime-grants.sh
│   └── schema
│       ├── README.md
│       └── 010_example.sql.disabled
├── scripts
│   ├── export-schema.sh
│   ├── generate-secrets.sh
│   └── refresh-runtime-grants.sh
├── secrets
└── backups
```

## Modelo de contas

| Conta | Finalidade |
|---|---|
| `SYS` / `SYSTEM` | Bootstrap e administração excepcional |
| `APP_ADMIN` | Administrador local do `FREEPDB1`, com role `DBA` |
| `APP_OWNER` | Proprietário de tabelas, índices, views e packages |
| `APP_RUNTIME` | Conexão da aplicação, sem privilégios de DDL |

O usuário de aplicação recebe uma role própria. Depois da criação dos objetos,
o projeto concede DML nas tabelas, leitura em views e sequences e execução em
procedures, functions e packages.

## Pré-requisitos no Oracle Container Registry

Antes do primeiro `pull`:

1. Acesse o Oracle Container Registry com uma conta Oracle.
2. Abra o repositório `database/free` e aceite os termos de uso, caso sejam
   solicitados para sua conta.
3. Autentique o Docker:

```bash
make login
```

## Primeiro uso

```bash
git clone https://github.com/carlosvblessa/oracle23ai-free-docker-compose.git
cd oracle23ai-free-docker-compose
make init
```

Revise `.env`. Os principais valores são:

```dotenv
ORACLE_IMAGE=container-registry.oracle.com/database/free:23.9.0.0
ORACLE_PLATFORM=linux/amd64
DB_ADMIN_USER=APP_ADMIN
DB_SCHEMA_USER=APP_OWNER
DB_RUNTIME_USER=APP_RUNTIME
DB_RUNTIME_ROLE=APP_RUNTIME_ROLE
DB_DATA_TABLESPACE=APP_DATA
DB_INDEX_TABLESPACE=APP_INDEX
```

Depois:

```bash
make login
make config
make pull
make up
make logs
```

O banco está pronto quando o container ficar `healthy` e o log mostrar:

```text
DATABASE IS READY TO USE!
```

Verifique:

```bash
make status
make version
```

## Conexão

| Parâmetro | Valor |
|---|---|
| Host no computador | `localhost` |
| Host para outro serviço Compose | `oracle` |
| Porta padrão | `1521` |
| Service name | `FREEPDB1` |
| CDB / SID | `FREE` |
| Schema owner | `APP_OWNER` |
| Usuário da aplicação | `APP_RUNTIME` |

JDBC:

```text
jdbc:oracle:thin:@//localhost:1521/FREEPDB1
```

No DBeaver, selecione **Service name** e informe `FREEPDB1`.

## SQL*Plus

```bash
make sql-sys
make sql-system
make sql-admin
make sql-owner
make sql-app
```

## Scripts de criação do esquema

Coloque os arquivos em `db/schema`, por exemplo:

```text
010_tables.sql
020_indexes.sql
030_sequences.sql
040_packages.sql
050_seed_data.sql
```

Na primeira inicialização de um volume vazio, a imagem oficial executa os
scripts montados em `/opt/oracle/scripts/setup`. Os arquivos do modelo são
executados como `DB_SCHEMA_USER`.

Para um banco já criado:

```bash
make apply-schema
```

Nesse caso, os arquivos devem ser idempotentes ou tratar objetos existentes.

## Persistência dos datafiles

O volume nomeado é montado em:

```text
/opt/oracle/oradata
```

Os tablespaces do projeto são criados explicitamente em:

```text
/opt/oracle/oradata/FREE/FREEPDB1
```

Isso evita que datafiles adicionais sejam criados acidentalmente dentro do
`ORACLE_HOME`, fora do volume persistente.

Remover somente o container e preservar os dados:

```bash
make down
```

Remover também o volume e reinicializar tudo:

```bash
make destroy
make up
```

`make destroy` apaga definitivamente o banco do laboratório.

## Atualizar grants

Depois de criar novos objetos:

```bash
make refresh-grants
```

## Exportação Data Pump

```bash
make backup
```

O Data Pump grava temporariamente em `/opt/oracle/oradata/backups`, e o script
copia os arquivos `.dmp` e `.log` para a pasta local `backups/`.

## Arquitetura da máquina

O projeto usa `linux/amd64`, adequado para computadores Intel e AMD de 64 bits.
Em uma máquina ARM64, confirme no Oracle Container Registry uma tag compatível
e ajuste `ORACLE_IMAGE` e `ORACLE_PLATFORM`. Não dependa de emulação para um
laboratório de reprodução de erro de banco de dados.

## Recomendações para reproduzir o problema real

Registre junto com o projeto:

- DDL completo dos objetos envolvidos;
- dados mínimos necessários para reproduzir o comportamento;
- parâmetros relevantes de `V$PARAMETER`;
- NLS, timezone, charset e versão do cliente;
- estatísticas dos objetos e plano de execução, quando for desempenho;
- versão completa mostrada por `make version`;
- comando ou operação exata que dispara o problema.

Não versione senhas, dumps com dados sensíveis ou arquivos do volume Oracle.
