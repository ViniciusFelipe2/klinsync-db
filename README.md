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

### Regras para novas migrations

- Arquivos `NNNN_descricao.sql` em ordem alfabética, cada um em transação. **Nunca edite** uma migration já aplicada (o checksum é validado): crie outra.
- Escreva-as compatíveis com a versão anterior da API (o deploy aplica as migrations antes de trocar o backend).
- Ao alterar o schema, rode `npm run sync-schema` no `klinsync-backend` para atualizar o espelho usado nos testes.

## Trazendo os dados do Supabase

A importação (tabelas, usuários com as senhas atuais, MFA e fotos para o S3) é feita pela ferramenta `import-supabase` do
[`klinsync-backend`](https://github.com/ViniciusFelipe2/klinsync-backend#migrando-os-dados-do-supabase), que grava neste schema numa única transação
e tem simulação (`--dry-run`). Aplique as migrations antes (`sudo klinsync-db-deploy`) e importe num banco vazio.
