# Preparação isolada da máquina destino

Este procedimento prepara um clone do projeto somente na máquina onde o
container será executado. Ele não conecta nem executa comandos no banco de
origem e não modifica o DDL recebido.

O DDL institucional é transformado localmente em
`db/schema/010_target_baseline.sql`. Esse arquivo, o `.env`, seus backups e os
secrets são ignorados pelo Git.

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
cria as senhas locais com permissão `600`, sem imprimi-las.

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

O procedimento pressupõe um volume novo. Caso o volume já exista, pare e
confirme seu conteúdo antes de continuar; os scripts de bootstrap da imagem
Oracle são executados somente na primeira inicialização do banco.

Para um destino novo:

```bash
make login
make pull
make up
make logs
```

Na primeira inicialização, a ordem é:

1. criação dos tablespaces, owner, loader e role;
2. execução de `010_target_baseline.sql` conectado como owner;
3. concessão da role ao loader e dos privilégios de DML nos objetos criados.

O DDL de baseline possui `CREATE TABLE` e não deve ser reaplicado com
`make apply-schema` sobre o mesmo volume sem antes torná-lo idempotente.

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
