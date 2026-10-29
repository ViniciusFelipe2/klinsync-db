# KlinSync DB

Schema PostgreSQL do KlinSync (PostgreSQL ≥ 13, sem extensões obrigatórias) e scripts de provisionamento/deploy da EC2 de banco.

```
migrations/
  0001_schema.sql   tipos, tabelas, índices e triggers (identidade, hospitais/módulos, segurança, check-in, giro)
  0002_seed.sql     dados de referência: módulos (features) e política de segurança padrão
scripts/            setup da EC2, migrate, deploy, backup, tune (ver scripts/README.md)
```

## Modelo

| Grupo | Tabelas |
| --- | --- |
| Identidade | `usuarios` (credencial, hash scrypt), `refresh_tokens` (rotação por família), `mfa_fatores` (TOTP cifrado) |
| Hospitais e acesso | `tenants`, `features`, `tenant_features`, `tenant_features_historico`, `usuarios_perfil`, `convites` |
| Segurança e auditoria | `log_acessos`, `log_acoes_sensiveis`, `config_seguranca`, `ip_bloqueios`, `rate_limits` |
| Check-in | `check_ins` (a foto fica no S3; aqui só o caminho) |
| Giro de sala | `salas`, `eventos_giro`, `eventos_sala_parada`, `sala_dispositivos` |

Diferenças em relação ao projeto mãe (Supabase):

- **Sem RLS e sem `auth.users`:** o controle de acesso por papel/hospital é feito pela API, e o banco só aceita a role `klinsync_app`.
  As credenciais viraram a tabela `usuarios`; `usuarios_perfil.id` aponta para ela.
- **Sem funções `private.*`/RPC:** reserva de sala, expurgo LGPD e diagnóstico de segurança agora são lógica da API.
- Papéis simplificados para `master_admin`, `hospital_admin` e `operador` (o legado `administrador` não existe).

## Aplicando

Na EC2 de DB isso é automático (`sudo klinsync-db-deploy` aplica as migrations pendentes e registra o checksum em `schema_migrations`).
Localmente:

```sh
createdb klinsync
psql klinsync -v ON_ERROR_STOP=1 -f migrations/0001_schema.sql -f migrations/0002_seed.sql
```

### Roles e privilégios (segurança)

| Role | Papel | Login |
| --- | --- | --- |
| `klinsync_owner` | Dono do banco e de todos os objetos. As migrations rodam como ela (`SET ROLE` feito pelo `migrate.sh`). | Não (`NOLOGIN`, sem senha) |
| `klinsync_app` | Usada pela API. Só `SELECT/INSERT/UPDATE/DELETE`; sem DDL, sem `TRUNCATE`. Nos logs de auditoria (`log_acoes_sensiveis`, `tenant_features_historico`) não tem nem `UPDATE`. | Sim |

- `ensure_db_roles` (em `scripts/common.sh`) cria/ajusta tudo de forma idempotente a cada `migrate`/`setup`, e define as *default privileges*: tabelas
  criadas por migrations futuras já ficam acessíveis (DML) à `klinsync_app`.
- A migration `0006_privilegios_minimos.sql` revoga o excesso nas tabelas existentes. Ela só age onde a role `klinsync_app` existe.
- **Cargas e importações com `TRUNCATE`** (o dump `klinsync-dados.sql`, `npm run import-supabase`) precisam rodar como dono, por exemplo
  `sudo -u postgres psql -d klinsync -c "SET ROLE klinsync_owner" -f - < klinsync-dados.sql`. A role da API não consegue.
- **TLS:** instalações novas aceitam o backend só por `hostssl`; o backend usa `DB_SSL=require`.

#### Atualizando um banco que já está no ar

1. `sudo klinsync-db-deploy`: o `migrate.sh` cria a role dona, transfere a posse dos objetos e aplica a `0006`. Nenhuma senha muda e a API continua conectando como `klinsync_app`.
2. Confira: `sudo -u postgres psql -d klinsync -c '\dt'` (dono = `klinsync_owner`) e, no painel master, a checagem "Aplicação com privilégios mínimos no banco" deve ficar **ok**.
3. TLS (opcional, depois de ligar `DB_SSL=require` no `/etc/klinsync/backend.env` e reiniciar a API): `sudo DB_REQUIRE_SSL=1 bash setup-ec2.sh` troca o `host` do `pg_hba.conf` por `hostssl`.

### Regras para novas migrations

- Arquivos `NNNN_descricao.sql` em ordem alfabética, cada um em transação. **Nunca edite** uma migration já aplicada (o checksum é validado): crie outra.
- Escreva-as compatíveis com a versão anterior da API (o deploy aplica as migrations antes de trocar o backend).
- Ao alterar o schema, rode `npm run sync-schema` no `klinsync-backend` para atualizar o espelho usado nos testes.

## Trazendo os dados do Supabase

A importação (tabelas, usuários com as senhas atuais, MFA e fotos para o S3) é feita pela ferramenta `import-supabase` do
[`klinsync-backend`](https://github.com/ViniciusFelipe2/klinsync-backend#migrando-os-dados-do-supabase), que grava neste schema numa única transação
e tem simulação (`--dry-run`). Aplique as migrations antes (`sudo klinsync-db-deploy`) e importe num banco vazio.
