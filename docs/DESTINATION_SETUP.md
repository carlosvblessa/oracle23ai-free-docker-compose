# Preparação isolada da máquina destino

Este procedimento prepara um clone do projeto somente na máquina onde o
container será executado. Ele não conecta nem executa comandos no banco de
origem e não modifica o DDL recebido.

O DDL institucional é transformado localmente em
`db/schema/010_target_baseline.sql`. Esse arquivo, o `.env`, seus backups e os
secrets são ignorados pelo Git.

O preparador também aceita um DDL que já contenha os ajustes físicos. Nesse
caso, ele valida owner, compressão e tablespaces e apenas posiciona uma cópia
para o bootstrap, sem reaplicar as cláusulas.

O projeto executa esse bootstrap explicitamente com `make provision`. Os
scripts são montados em `/project/setup`, fora do gancho automático da imagem
Oracle, para que falhas de permissão não sejam silenciosamente ignoradas.

## Pré-requisitos da máquina

Além de Docker Engine, Docker Compose e `openssl`, instale o suporte a ACL
POSIX. No Ubuntu ou Debian:

```bash
sudo apt install acl
```

No RHEL, Oracle Linux ou Fedora:

```bash
sudo dnf install acl
```

O UID interno da conta `oracle` é `54321`. O preparador mantém secrets e DDL
privado com modo `600` e concede leitura somente a esse UID via ACL.

## O que é preservado da origem

O DDL derivado mantém os seguintes atributos relevantes para a carga:

- `SEGMENT CREATION IMMEDIATE`;
- `PCTFREE 0` na tabela;
- `COMPRESS BASIC` e `NOLOGGING` na tabela;
- `PCTFREE 10`, `INITRANS 2`, `COMPRESS 1`, `COMPUTE STATISTICS` e
  `NOLOGGING` nos índices;
- separação entre tablespace de dados e de índices.

Não são copiados `PCTUSED`, `MAXTRANS`, `FREELISTS`, `FREELIST GROUPS`,
`BUFFER_POOL`, `FLASH_CACHE`, `CELL_FLASH_CACHE` nem os valores de `STORAGE`.
O projeto cria tablespaces localmente gerenciados com gerenciamento automático
de espaço; esses atributos são obsoletos, são defaults ou pertencem à
infraestrutura física da origem. Os nomes dos tablespaces podem ser mantidos
por meio das variáveis de preparação.

## Preparar o clone no destino

Copie o DDL por um canal seguro para a máquina destino e execute, na raiz do
projeto:

```bash
TARGET_SCHEMA_USER=SCHEMA_OWNER \
TARGET_LOADER_USER=ETL_LOADER \
TARGET_LOADER_ROLE=SCHEMA_LOAD_ROLE \
TARGET_DATA_TABLESPACE=SOURCE_DATA_TABLESPACE \
TARGET_INDEX_TABLESPACE=SOURCE_INDEX_TABLESPACE \
./scripts/prepare-target.sh /caminho/seguro/ddl_origem.sql
```

O preparador usa as variáveis `DB_RUNTIME_USER` e `DB_RUNTIME_ROLE` existentes
no projeto para representar, respectivamente, o usuário e a role de carga. Ele
cria as senhas locais com permissão `600`, sem imprimi-las, e configura as ACLs
necessárias para os arquivos montados no container.

Se um DDL destino já tiver sido gerado e precisar ser substituído, revise o
arquivo de origem e use explicitamente:

```bash
./scripts/prepare-target.sh --force /caminho/seguro/ddl_origem.sql
```

As cinco variáveis `TARGET_*` continuam sendo obrigatórias nesse comando.

## Criar o container

Revise primeiro os arquivos gerados:

```bash
git status --short --ignored
docker volume ls --filter name=oracle23ai-data
make config
```

O procedimento pressupõe um volume novo. Caso o volume já exista, confirme seu
conteúdo antes de continuar. `make provision` registra sua conclusão em um
marcador dentro do volume e não reaplica o baseline quando esse marcador já
existe.

Para um destino novo:

```bash
make pull
make up
make provision
make verify
```

O pull dessa imagem é público e normalmente não exige autenticação. Se o
registry responder explicitamente com erro de autenticação, execute
`make login` usando a conta Oracle Single Sign-On, e não o usuário Linux.

`make up` inicia somente o Oracle. `make provision` espera o healthcheck ficar
saudável e então executa, com verificação de cada erro:

1. criação dos tablespaces, owner, loader e role;
2. execução de `010_target_baseline.sql` conectado como owner;
3. concessão da role ao loader e dos privilégios de DML nos objetos criados;
4. validação e gravação do marcador de provisionamento no volume.

Para acompanhar o Oracle em outro terminal:

```bash
make logs
```

O DDL de baseline possui `CREATE TABLE` e não deve ser reaplicado com
`make apply-schema` sobre o mesmo volume sem antes torná-lo idempotente. O
marcador protege `make provision`, mas `make apply-schema` é deliberadamente um
comando manual e percorre novamente todos os arquivos `*.sql`.

O baseline mantém os três índices antes da carga para reproduzir o DDL
recebido. Se a carga inicial tiver grande volume, considere separar a criação
dos índices para depois da carga: manter índices durante cada `INSERT` aumenta
o trabalho do banco. Essa mudança deve ser decidida antes de iniciar o
container, pois altera a sequência operacional.

Como tabela e índices usam `NOLOGGING`, gere um backup depois da carga inicial:

```bash
make backup
```

## Validar no destino

Depois que o container estiver `healthy`, conecte como administrador:

```bash
make status
make verify
make sql-admin
```

Confira a distribuição física:

```sql
SELECT owner,
       table_name,
       tablespace_name,
       compression,
       compress_for,
       logging,
       pct_free
  FROM dba_tables
 WHERE owner = 'SCHEMA_OWNER';

SELECT owner,
       index_name,
       table_name,
       tablespace_name,
       compression,
       prefix_length,
       logging,
       pct_free,
       ini_trans
  FROM dba_indexes
 WHERE owner = 'SCHEMA_OWNER'
 ORDER BY index_name;

SELECT grantee,
       owner,
       table_name,
       privilege
  FROM dba_tab_privs
 WHERE grantee = 'SCHEMA_LOAD_ROLE'
 ORDER BY table_name, privilege;
```

O loader deve usar nomes qualificados, como
`SCHEMA_OWNER.NOME_DA_TABELA`, ou configurar
`ALTER SESSION SET CURRENT_SCHEMA = SCHEMA_OWNER`. Isso não amplia seus
privilégios; apenas altera a resolução dos nomes.

## Solução de problemas de permissão

Se aparecer `Permission denied` ao ler `/run/secrets/*` ou `SP2-0310` para um
arquivo de `/project/schema`, reaplique as ACLs:

```bash
make access
```

Confirme dentro do container:

```bash
ORACLE_PWD="$(tr -d '\r\n' < secrets/oracle_password.txt)" \
docker compose exec -T oracle bash -lc '
  test -r /run/secrets/db_admin_password
  test -r /project/schema/010_target_baseline.sql
  echo "Secrets e DDL acessíveis"
'
```

Não é necessário destruir o volume para corrigir apenas permissões. Depois de
uma falha de permissão ocorrida antes da abertura do DDL, execute
`make provision`; a criação de usuários e tablespaces é idempotente, e o
marcador só é gravado depois que DDL e grants terminam com sucesso. Se um DDL
chegou a executar parcialmente, inspecione os objetos antes da nova tentativa,
pois comandos DDL do Oracle fazem commit implícito.

O executor habilita `SQLBLANKLINES ON` para aceitar DDLs com linhas em branco
dentro das instruções e também inspeciona a saída, tratando qualquer `SP2-*`
como falha mesmo quando o processo SQL*Plus retorna código zero.

## Atualizar um clone criado com a versão anterior

Depois de receber estas correções, preserve o volume existente e execute:

```bash
git pull
make up
make provision
make verify
```

`make up` recriará somente o container para trocar o mount dos scripts de
`/opt/oracle/scripts/setup` para `/project/setup`; o volume de dados não será
removido. Não use `make destroy` nessa atualização.

Se esse volume antigo já tiver objetos e `make provision` recusar a
reaplicação por ausência do marcador, primeiro confira o resultado de
`make verify`. Somente se o provisionamento legado estiver completo, execute:

```bash
make adopt-provisioned
```
