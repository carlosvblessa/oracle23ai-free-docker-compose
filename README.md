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
Secrets montados a partir de arquivos locais.

O Docker Compose implementa esses secrets locais como bind mounts e não altera
seu proprietário para o UID do container. O projeto mantém secrets e DDLs
privados sem acesso para `other` e usa ACL POSIX para conceder leitura somente
ao usuário `oracle` da imagem, UID `54321`.

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
│   │   ├── 003-runtime-grants.sh
│   │   └── 004-verify.sh
│   └── schema
│       ├── README.md
│       └── 010_example.sql.disabled
├── scripts
│   ├── export-schema.sh
│   ├── configure-container-access.sh
│   ├── generate-secrets.sh
│   ├── prepare-target.sh
│   ├── provision.sh
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

## Pré-requisitos

- Docker Engine com o plugin Docker Compose;
- `openssl` para gerar senhas;
- `setfacl`, fornecido pelo pacote `acl`.

Ubuntu ou Debian:

```bash
sudo apt install acl
```

RHEL, Oracle Linux ou Fedora:

```bash
sudo dnf install acl
```

### Oracle Container Registry

A imagem `container-registry.oracle.com/database/free:23.9.0.0` pode ser
baixada publicamente. Tente diretamente:

```bash
make pull
```

Não execute `make login` preventivamente. Se o registry responder
explicitamente com erro de autenticação, use `make login` e informe a conta do
Oracle Single Sign-On — não o usuário Linux da máquina — e repita o pull.

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
NLS_LANG=.AL32UTF8
DB_ADMIN_USER=APP_ADMIN
DB_SCHEMA_USER=APP_OWNER
DB_RUNTIME_USER=APP_RUNTIME
DB_RUNTIME_ROLE=APP_RUNTIME_ROLE
DB_DATA_TABLESPACE=APP_DATA
DB_INDEX_TABLESPACE=APP_INDEX
```

Depois:

```bash
make config
make pull
make up
make provision
make verify
```

`make provision` aguarda o healthcheck ficar `healthy`. Para acompanhar apenas
os logs, em outro terminal, use:

```bash
make logs
```

As mensagens `[provision]`, `[bootstrap]`, `[schema]` e `[grants]` aparecem no
terminal que executa `make provision`; elas não fazem parte do log principal do
container.

O Oracle está disponível quando o log mostrar:

```text
DATABASE IS READY TO USE!
```

Verificações operacionais adicionais:

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

Para executar um arquivo SQL não interativamente como o usuário da aplicação,
sem montar o arquivo no container, use `SQL_FILE`:

```bash
mkdir -p local/sql
make sql-app-file SQL_FILE=local/sql/consulta.sql
```

O executor lê o arquivo no host e o envia ao SQL*Plus por `stdin` com TTY
desabilitado. Ele interrompe em erros Oracle ou do sistema, também trata erros
`SP2-*` como falha e habilita `SQLBLANKLINES ON`. O diretório `local/` já é
ignorado pelo Git e é apropriado para consultas operacionais que não devem ser
versionadas. Scripts chamados com `@outro-arquivo.sql` precisam estar acessíveis
dentro do container; para consultas independentes, prefira um único arquivo.

### Codificação UTF-8 no SQL*Plus

`ORACLE_CHARACTERSET` define o charset usado quando o banco é criado. Ele não
define como um cliente Oracle interpreta os bytes de um arquivo. O SQL*Plus usa
o componente de charset de `NLS_LANG`; por isso o padrão do projeto é:

```dotenv
NLS_LANG=.AL32UTF8
```

A forma sem idioma e território altera somente o charset do cliente. A imagem
oficial fixada pelo projeto também contém o locale `C.utf8`, configurado em
`LANG` e `LC_ALL` no container. Mantenha todos os scripts SQL, inclusive os de
`local/ddl`, em UTF-8. O diretório `local/` é específico do ambiente, já está no
`.gitignore` e não deve ser versionado; o mesmo vale para `.env`, secrets e SQLs
reais.

Não é necessário nem recomendado alterar o charset do banco existente. Para
aplicar o novo ambiente ao container sem tocar no volume, valide e recrie
somente o serviço real `oracle`:

```bash
make config
ORACLE_PWD="$(tr -d '\r\n' < secrets/oracle_password.txt)" \
docker compose up -d --force-recreate oracle
```

O valor da senha é passado somente no ambiente do processo do Compose e não é
impresso. Não use `docker compose down -v`. Confirme o ambiente efetivo:

```bash
docker inspect oracle23ai-db \
  --format '{{range .Config.Env}}{{println .}}{{end}}' |
grep '^NLS_LANG='
```

Resultado esperado:

```text
NLS_LANG=.AL32UTF8
```

Teste a leitura UTF-8 pelo SQL*Plus sem heredoc:

```bash
printf '%s\n' \
  'SET HEADING OFF' \
  'SET FEEDBACK OFF' \
  'SET PAGESIZE 0' \
  "SELECT ASCIISTR('Número Código Situação') FROM dual;" \
  'EXIT;' |
docker exec -i oracle23ai-db \
  sqlplus -s "/ as sysdba"
```

O resultado deve ser `N\00FAmero C\00F3digo Situa\00E7\00E3o`, nunca uma
sequência com `\FFFD`.

## Scripts de criação do esquema

Coloque os arquivos em `db/schema`, por exemplo:

```text
010_tables.sql
020_indexes.sql
030_sequences.sql
040_packages.sql
050_seed_data.sql
```

O projeto não depende do gancho automático `/opt/oracle/scripts/setup` da
imagem. Os scripts são montados no diretório neutro `/project/setup` e
executados explicitamente por:

```bash
make provision
```

O provisionamento segue esta ordem:

1. espera o healthcheck do Oracle;
2. valida a leitura dos secrets, scripts e DDLs dentro do container;
3. cria ou atualiza tablespaces, usuários e role;
4. executa `db/schema/*.sql`, em ordem lexical, como `DB_SCHEMA_USER`;
5. concede os privilégios dos objetos para `DB_RUNTIME_ROLE`;
6. valida usuários, tablespaces, objetos e role;
7. grava um marcador no volume persistente.

Se o marcador já existir, `make provision` não reaplica o baseline. Isso evita
falhas de `CREATE TABLE` em um volume já preparado.

Se um volume sem marcador já possuir objetos do owner, o provisionamento para
antes do DDL. Após confirmar que se trata de um ambiente legado completo, use
`make verify` e `make adopt-provisioned`; a adoção só cria o marcador quando a
validação é bem-sucedida.

Para aplicar posteriormente arquivos novos e idempotentes:

```bash
make apply-schema
```

Esse comando percorre novamente todos os arquivos `*.sql`; portanto, eles devem
ser idempotentes ou tratar objetos existentes. Erros SQL e erros do SQL*Plus,
como `SP2-0310` e `SP2-0734`, interrompem o comando antes da atualização de
grants. O executor habilita `SQLBLANKLINES ON`, permitindo linhas em branco
dentro de instruções SQL recebidas de ferramentas como DBeaver.

## Permissões dos arquivos montados

`make init`, `scripts/prepare-target.sh`, `make provision`, `make sql-admin`,
`make sql-owner`, `make sql-app`, `make apply-schema` e `make backup` aplicam ou
reaplicam automaticamente as ACLs necessárias.

Para reaplicá-las manualmente depois de substituir um secret ou DDL:

```bash
make access
```

O DDL privado pode continuar com modo `600`; a entrada ACL permite leitura
somente ao UID `54321` do container. Não use `chmod 644` em secrets para
contornar problemas de acesso.

## Preparação isolada de um destino

Para reproduzir um esquema a partir de um DDL que não deve ser versionado,
use o preparador local descrito em
[`docs/DESTINATION_SETUP.md`](docs/DESTINATION_SETUP.md). O procedimento gera
o `.env`, os secrets e um DDL adaptado somente no clone da máquina destino.

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
make provision
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
