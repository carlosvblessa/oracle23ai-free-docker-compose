# Secrets locais

Execute `make init` ou `make secrets`. Serão criados:

- `oracle_password.txt`: senha comum de SYS, SYSTEM e PDBADMIN;
- `db_admin_password.txt`: administrador local do PDB;
- `db_schema_password.txt`: proprietário do esquema;
- `db_runtime_password.txt`: usuário da aplicação.

Os arquivos são criados com permissão `600` e são ignorados pelo Git.

## Limitação da imagem oficial com Docker Compose

A imagem oficial recebe a senha administrativa pela variável `ORACLE_PWD`.
Ela não implementa `ORACLE_PWD_FILE` para Docker Compose. Por isso, o Makefile
lê `oracle_password.txt` e exporta seu conteúdo apenas no processo que chama
`docker compose`.

A senha ainda ficará visível para quem possuir permissão para inspecionar o
container com Docker. Esta é uma limitação explícita deste desenho. Os outros
três arquivos são montados como Docker Secrets e lidos pelos scripts SQL.
