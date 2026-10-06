# Scripts da EC2 de DB

Provisionam a EC2 (PostgreSQL nativo + Node 22 + PM2), aplicam as migrations e fazem o deploy puxando o código do bucket **`s3://klinsync-db`**.

| Script         | Onde roda                  | O que faz                                                                                      |
| -------------- | -------------------------- | ---------------------------------------------------------------------------------------------- |
| `setup-ec2.sh` | EC2 (uma vez, root)        | Instala Postgres/Node/PM2, cria banco e role, libera só o backend, backup diário, PM2 no boot |
| `deploy.sh`    | EC2 (`klinsync-db-deploy`) | Baixa a release do S3, aplica migrations, atualiza o app Node (se houver) no PM2               |
| `migrate.sh`   | EC2 (`klinsync-db-migrate`) | Aplica `migrations/*.sql` pendentes com controle em `public.schema_migrations`                |
| `tune.sh`      | EC2 (`klinsync-db-tune`)   | Dimensiona Postgres/app Node/kernel conforme vCPU e RAM da instância (roda também no boot)     |
| `backup.sh`    | EC2 (`klinsync-db-backup`) | `pg_dump -Fc` com retenção local (14 dias) e cópia em `s3://klinsync-db/backups/`              |
| `publish.sh`   | Sua máquina / CI           | `git archive` do HEAD → S3; `--deploy` aciona a EC2 via SSM                                    |
| `common.sh`    | —                          | Funções compartilhadas                                                                         |

## Layout no S3

```
s3://klinsync-db/
  releases/klinsync-db-<data>-<sha>.tar.gz   migrations/*.sql na raiz (+ app Node opcional)
  releases/latest.txt                         chave da release atual
  scripts/                                    cópia destes scripts (usada no 1º setup)
  backups/                                    dumps diários do banco
```

## Versionamento e espelho do GitHub no S3

- **Versão semântica 100% automática:** a cada push na `main` o workflow lê as mensagens dos commits desde a última tag (padrão *Conventional Commits*) e decide o incremento:
  `feat!:` ou `BREAKING CHANGE` → **major**, `feat:` → **minor**, qualquer outro (`fix:`, `docs:`, `chore:`...) → **patch**. Depois cria a tag `vX.Y.Z` e a **GitHub Release** com notas automáticas
  (a primeira publicação é `v0.1.0`). Nenhuma ação manual é necessária; no disparo manual (Actions → Run workflow) dá para forçar `patch`/`minor`/`major`.
  Reexecutar o workflow no mesmo commit reaproveita a versão já criada.
- **Histórico no bucket:** o versionamento do S3 está ligado em `klinsync-db`; versões antigas e arquivos removidos ficam recuperáveis por **90 dias**
  (regra de lifecycle `klinsync-expire-noncurrent-versions`). Para restaurar: `aws s3api list-object-versions --bucket klinsync-db --prefix <chave>`.
- **Espelho:** `scripts/` é sincronizado com `--delete` e o código vai como release `releases/klinsync-db-v<versão>-<data>-<sha>.tar.gz`
  (metadados `version`, `commit`, `run`). Só as **20 últimas releases** ficam no bucket (`KEEP_RELEASES_S3`); `latest.txt` sempre aponta para a mais nova.
  Os dumps em `backups/` **não** são apagados automaticamente.

## Primeira vez

1. **IAM da EC2** — instance profile com `AmazonSSMManagedInstanceCore` e a policy inline abaixo.
2. Na máquina local: `scripts/publish.sh`.
3. Na EC2 de DB (Ubuntu 24.04 ou Amazon Linux 2023), informando o **IP privado do backend**:

```sh
aws s3 sync s3://klinsync-db/scripts /tmp/klinsync-db-scripts --region us-east-2
sudo BACKEND_PRIVATE_IP=10.0.1.10 bash /tmp/klinsync-db-scripts/setup-ec2.sh
sudo cat /root/klinsync-db-credenciais.txt     # copie o DATABASE_URL para o backend.env e apague o arquivo
sudo klinsync-db-deploy
```

## Dia a dia

```sh
scripts/publish.sh --deploy      # (local) publica e atualiza a EC2 via SSM (EC2_INSTANCE_ID=i-...)
sudo klinsync-db-deploy          # (EC2) puxa a última release do S3, migra e atualiza o app
sudo klinsync-db-migrate         # (EC2) reaplica apenas as migrations pendentes
sudo klinsync-db-backup          # (EC2) backup manual
```

## Detecção do sistema e dimensionamento automático

**Sistema:** o `setup-ec2.sh` lê `/etc/os-release` e escolhe o caminho de instalação:

| Sistema                  | Pacotes | Postgres                                  | Firewall       |
| ------------------------ | ------- | ----------------------------------------- | -------------- |
| Ubuntu 22.04 / 24.04     | `apt`   | `postgresql` (versão da distro: 14 / 16)  | UFW + fail2ban |
| Debian 12 / 13           | `apt`   | `postgresql` (versão da distro)           | UFW + fail2ban |
| Amazon Linux 2023        | `dnf`   | `postgresql16-server` + `postgresql-setup --initdb` | Security Group |
| Amazon Linux 2, outros   | —       | recusado com mensagem clara               | —              |

Arquiteturas `x86_64` e `aarch64` (Graviton) são suportadas.

**Tamanho:** lê vCPU, RAM, swap, disco livre e o tipo da instância (IMDSv2) e valida:

- Mínimo para rodar: **700 MB de RAM e 5 GB livres**. Abaixo disso o script para (`FORCE_SIZE=1` ignora, não recomendado).
  Recomendado: 2 vCPU e ~2 GB (t3.small ou maior) e disco com folga para dados + backups.
- Com menos de 2 GB de RAM e sem swap, cria `/swapfile` (2× a RAM, entre 1 e 4 GB).

**Ajuste de recursos** (`tune.sh`, via `ALTER SYSTEM`): reserva memória para o SO (256–1024 MB) e para o app Node
(10% da RAM, entre 128 e 512 MB); o restante é do Postgres.

| Parâmetro                     | Regra                                          | t3.small (2 vCPU/2 GB) | m5.large (2 vCPU/8 GB) | r5.xlarge (4 vCPU/32 GB) |
| ----------------------------- | ---------------------------------------------- | ---------------------- | ---------------------- | ------------------------ |
| `shared_buffers`              | 25% da RAM do Postgres                         | 299 MB                 | 1630 MB                | 7366 MB                  |
| `effective_cache_size`        | 70% da RAM total (menos o SO)                  | 971 MB                 | 4922 MB                | 20983 MB                 |
| `max_connections`             | RAM do Postgres / 8 (40 a 200)                 | 149                    | 200                    | 200                      |
| `work_mem`                    | (RAM − shared) / (conexões × 3), 1 a 64 MB     | 2 MB                   | 8 MB                   | 37 MB                    |
| `maintenance_work_mem`        | RAM / 16 (32 MB a 2 GB)                        | 118 MB                 | 487 MB                 | 1937 MB                  |
| Paralelismo                   | `max_worker_processes` = vCPU (4 a 32); por consulta = vCPU/2 (0 com 1 vCPU, máx. 4) | 4 / 1 | 4 / 1 | 4 / 2 |
| WAL / checkpoints             | `min/max_wal_size` e `wal_buffers` por RAM; `checkpoint_completion_target=0.9` | | | |
| SSD (gp3)                     | `random_page_cost=1.1`, `effective_io_concurrency=200` | | | |
| App Node (PM2)                | heap = 70% do orçamento; reinício em 100%      | 133 MB                 | 358 MB                 | 358 MB                   |
| Kernel                        | `vm.swappiness=10`, `vm.dirty_*` moderados     |                        |                        |                          |

Como aplicar e ajustar:

- O `setup-ec2.sh` já chama o `tune.sh`. Para refazer a qualquer momento: `sudo klinsync-db-tune`.
- O Postgres **só é reiniciado** se algum parâmetro novo exigir (`shared_buffers`, `max_connections`...), com queda de conexões por alguns segundos.
- O serviço `klinsync-db-tune.service` roda a cada boot e **só reaplica se o tipo/vCPU/RAM mudou**: ao redimensionar a EC2
  (parar → trocar o tipo → iniciar) o Postgres se reajusta sozinho.
- **Pool no backend:** o `max_connections` calculado é impresso no fim do `tune.sh` e gravado em
  `/root/klinsync-db-credenciais.txt` (`DB_MAX_CONNECTIONS`). Informe-o no backend (`/etc/klinsync/deploy.env`) e rode
  `sudo klinsync-tune` lá para o pool por instância caber nesse limite.

## Regras de migrations

- Arquivos `migrations/NNNN_descricao.sql`, aplicados em ordem alfabética, cada um em transação.
- **Nunca edite** uma migration já aplicada (o checksum é validado); crie outra.
- Rodam como o dono do banco (`klinsync_app`). `pgcrypto` já vem habilitada; outras extensões precisam de superusuário
  (`sudo -u postgres psql -d klinsync -c 'CREATE EXTENSION ...'`).
- As migrations do projeto mãe (`trizion/supabase/migrations`) usam recursos do Supabase (schema `auth`, `auth.uid()`,
  roles `anon`/`authenticated`, RLS) e **não rodam em Postgres puro** sem adaptação.

## App Node opcional (PM2)

Se a release tiver `package.json` e o arquivo `dist/index.js` (`DB_APP_ENTRY`), o deploy o inicia no PM2 em `HOST:PORT`
(IP privado, porta 4000), lendo `/etc/klinsync/db.env`, e valida `GET /health`. Sem isso, só as migrations são aplicadas.

## Arquivos na EC2

| Caminho                                       | Conteúdo                                              |
| --------------------------------------------- | ----------------------------------------------------- |
| `/etc/klinsync/db-deploy.env`                 | Bucket, banco, porta, entrada do app e dimensionamento calculado (sem segredos) |
| `/opt/klinsync-db/ecosystem.config.cjs`       | Configuração do PM2 (gerada pelo `tune.sh`; não edite) |
| `/etc/sysctl.d/99-klinsync-db.conf`           | Ajustes de kernel (gerado pelo `tune.sh`)             |
| `/etc/klinsync/db.env`                        | `DATABASE_URL` local e porta do app (`root:klinsync`, 640) |
| `/root/klinsync-db-credenciais.txt`           | `DATABASE_URL` para o backend (apagar após copiar)    |
| `/opt/klinsync-db/releases/*` e `current`     | Releases extraídas (mantém 5)                         |
| `/var/backups/klinsync/*.dump`                | Backups locais                                        |

## Policy inline da role da EC2

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::klinsync-db" },
    { "Effect": "Allow", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::klinsync-db/*" },
    { "Effect": "Allow", "Action": "s3:PutObject", "Resource": "arn:aws:s3:::klinsync-db/backups/*" }
  ]
}
```

## Rede e segurança

- O Postgres escuta em `localhost` + IP privado e o `pg_hba.conf` só aceita o IP do backend (`scram-sha-256`).
- Security Group da EC2 de DB: **nenhuma porta pública**; 5432 (e 4000, se usar o app) apenas a partir do SG do backend.
- Restauração: `pg_restore -d klinsync --clean --if-exists arquivo.dump` (como `postgres`).
- Marque os scripts como executáveis no Git: `git update-index --chmod=+x scripts/*.sh`.
