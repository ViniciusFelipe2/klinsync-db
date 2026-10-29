#!/usr/bin/env bash
# =============================================================================
# KlinSync — Preparação ÚNICA da EC2 de DB (PostgreSQL nativo + Node 22 + PM2)
#
# Detecta o sistema (Ubuntu 22.04/24.04, Debian 12/13 ou Amazon Linux 2023) e o tamanho da
# instância (vCPU/RAM/disco) e ajusta o PostgreSQL, o app Node e o kernel aos recursos disponíveis.
# Rodar como root:
#
#   sudo BACKEND_PRIVATE_IP=10.0.1.10 bash setup-ec2.sh
#
# - PostgreSQL gerenciado pelo systemd; escuta no IP privado e aceita só o backend.
# - PM2 gerencia o app Node do klinsync-db (opcional, vem do bucket S3).
# - Migrations (migrations/*.sql) aplicadas pelo deploy; backup diário do banco.
# Idempotente: pode ser rodado de novo (não troca a senha do banco existente).
# Para reajustar após redimensionar a EC2: klinsync-db-tune.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

# ----------------------------- CONFIGURAÇÃO ----------------------------------
AWS_REGION="${AWS_REGION:-us-east-2}"
DB_BUCKET="${DB_BUCKET:-klinsync-db}"
BACKEND_PRIVATE_IP="${BACKEND_PRIVATE_IP:-}"   # IP privado da EC2 de backend (obrigatório)
DB_NAME="${DB_NAME:-klinsync}"
DB_USER="${DB_USER:-klinsync_app}"
APP_DIR="${APP_DIR:-/opt/klinsync-db}"
DB_APP_ENTRY="${DB_APP_ENTRY:-dist/index.js}"  # entrada do app Node do klinsync-db (se existir)
DB_APP_PORT="${DB_APP_PORT:-4000}"
DB_APP_HEALTH_PATH="${DB_APP_HEALTH_PATH:-/health}"
PM2_APP_NAME="${PM2_APP_NAME:-klinsync-db}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
# -----------------------------------------------------------------------------

require_root
[ -n "$BACKEND_PRIVATE_IP" ] || die "Defina BACKEND_PRIVATE_IP (IP privado da EC2 de backend)."
detect_os
detect_resources
log "Sistema: $OS_NAME ($ARCH) | gerenciador: $PKG | firewall: $FIREWALL"
validate_size db
ensure_swap

DB_PRIVATE_IP="$(hostname -I | awk '{print $1}')"

log "Atualizando sistema e instalando dependências ($PKG)"
if [ "$PKG" = apt ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y
  pkg_install ca-certificates curl gnupg unzip openssl ufw fail2ban unattended-upgrades postgresql postgresql-contrib
  dpkg-reconfigure -f noninteractive unattended-upgrades
else
  dnf upgrade -y
  pkg_install curl-minimal unzip openssl tar gzip postgresql16-server postgresql16-contrib
  if [ ! -s /var/lib/pgsql/data/PG_VERSION ]; then postgresql-setup --initdb; fi
fi
systemctl enable --now postgresql

log "Instalando Node.js 22, AWS CLI e PM2"
if ! command -v node >/dev/null 2>&1 || ! node -v | grep -q '^v22'; then
  if [ "$PKG" = apt ]; then curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  else curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -; fi
  pkg_install nodejs
fi
if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$ARCH.zip" -o /tmp/awscli.zip
  unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscli.zip
fi
npm install -g pm2

log "Criando usuário e diretórios"
id "$APP_USER" >/dev/null 2>&1 || useradd --system --create-home --home-dir "$APP_HOME" --shell /usr/sbin/nologin "$APP_USER"
mkdir -p "$APP_DIR/releases" "$CONFIG_DIR" "$LIB_DIR" /var/backups/klinsync
chown -R "$APP_USER:$APP_USER" "$APP_DIR"
chmod 755 "$CONFIG_DIR"

log "Configurando o PostgreSQL (acesso, banco e role)"
HBA_FILE="$(psql_admin -tAc 'SHOW hba_file')"
psql_admin -c "ALTER SYSTEM SET listen_addresses = 'localhost,$DB_PRIVATE_IP'"
psql_admin -c "ALTER SYSTEM SET password_encryption = 'scram-sha-256'"
# TLS entre o backend e o banco. No Debian/Ubuntu o pacote já traz um certificado autoassinado; no Amazon Linux geramos um.
PGDATA_DIR="$(psql_admin -tAc 'SHOW data_directory')"
if [ ! -s "$PGDATA_DIR/server.crt" ] && [ ! -s /etc/ssl/certs/ssl-cert-snakeoil.pem ]; then
  openssl req -new -x509 -days 3650 -nodes -subj "/CN=klinsync-db" -out "$PGDATA_DIR/server.crt" -keyout "$PGDATA_DIR/server.key"
  chown postgres:postgres "$PGDATA_DIR/server.crt" "$PGDATA_DIR/server.key"
  chmod 600 "$PGDATA_DIR/server.key"
fi
psql_admin -c "ALTER SYSTEM SET ssl = 'on'"
HBA_MARK="# klinsync-backend"
if ! grep -q "$HBA_MARK" "$HBA_FILE"; then
  # Instalação nova: só aceita o backend com TLS (hostssl). O backend sobe com DB_SSL=require.
  printf '%s\nhostssl %s    %s    %s/32    scram-sha-256\n' "$HBA_MARK" "$DB_NAME" "$DB_USER" "$BACKEND_PRIVATE_IP" >> "$HBA_FILE"
elif [ "${DB_REQUIRE_SSL:-0}" = "1" ]; then
  # Instalação existente: só endurece quando pedido (o backend precisa ter DB_SSL=require antes, senão perde o banco).
  sed -i "/^$HBA_MARK/{n;s/^host\([[:space:]]\)/hostssl\1/}" "$HBA_FILE"
fi
systemctl restart postgresql

DB_PASSWORD=""
if ! psql_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
  DB_PASSWORD="$(openssl rand -hex 24)"
  psql_admin -v pw="$DB_PASSWORD" <<SQL
CREATE ROLE $DB_USER LOGIN PASSWORD :'pw';
SQL
fi
if ! psql_admin -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
  psql_admin -c "CREATE DATABASE $DB_NAME OWNER $DB_USER"
fi
psql_admin -c "REVOKE ALL ON DATABASE $DB_NAME FROM PUBLIC"
psql_admin -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto"
# A API (klinsync_app) fica só com DML; o dono dos objetos é a role de grupo klinsync_owner (assumida pelas migrations).
ensure_db_roles

if [ -n "$DB_PASSWORD" ]; then
  log "Gravando credenciais"
  cat > "$DB_ENV" <<EOF
# Usado pelas migrations e pelo app Node desta EC2 (carregado via node --env-file).
NODE_ENV=production
PORT=$DB_APP_PORT
HOST=$DB_PRIVATE_IP
DATABASE_URL=postgresql://$DB_USER:$DB_PASSWORD@127.0.0.1:5432/$DB_NAME
EOF
  chown "root:$APP_USER" "$DB_ENV"; chmod 640 "$DB_ENV"
  cat > "$CREDENTIALS_FILE" <<EOF
# GUARDE EM LOCAL SEGURO E APAGUE ESTE ARQUIVO DEPOIS.
# Use no /etc/klinsync/backend.env da EC2 de backend (e mantenha DB_SSL=require):
DATABASE_URL=postgresql://$DB_USER:$DB_PASSWORD@$DB_PRIVATE_IP:5432/$DB_NAME
DB_SSL=require
EOF
  chmod 600 "$CREDENTIALS_FILE"
else
  warn "Role $DB_USER já existia: senha e $DB_ENV mantidos."
fi

log "Gravando $DEPLOY_ENV (configuração sem segredos)"
cat > "$DEPLOY_ENV" <<EOF
AWS_REGION=$AWS_REGION
AWS_DEFAULT_REGION=$AWS_REGION
DB_BUCKET=$DB_BUCKET
DB_NAME=$DB_NAME
APP_DIR=$APP_DIR
DB_APP_ENTRY=$DB_APP_ENTRY
DB_APP_PORT=$DB_APP_PORT
DB_APP_HEALTH_PATH=$DB_APP_HEALTH_PATH
PM2_APP_NAME=$PM2_APP_NAME
BACKUP_RETENTION_DAYS=$BACKUP_RETENTION_DAYS
KEEP_RELEASES=5
EOF
chmod 644 "$DEPLOY_ENV"

log "Instalando scripts de operação"
install -m 0755 "$SCRIPT_DIR"/{common.sh,deploy.sh,migrate.sh,backup.sh,tune.sh} "$LIB_DIR/"
ln -sfn "$LIB_DIR/deploy.sh"  /usr/local/bin/klinsync-db-deploy
ln -sfn "$LIB_DIR/migrate.sh" /usr/local/bin/klinsync-db-migrate
ln -sfn "$LIB_DIR/backup.sh"  /usr/local/bin/klinsync-db-backup
ln -sfn "$LIB_DIR/tune.sh"    /usr/local/bin/klinsync-db-tune
echo "0 3 * * * root /usr/local/bin/klinsync-db-backup >> /var/log/klinsync-db-backup.log 2>&1" > /etc/cron.d/klinsync-db-backup

log "Configurando PM2 no boot"
as_app pm2 install pm2-logrotate >/dev/null
as_app pm2 set pm2-logrotate:max_size 20M >/dev/null
as_app pm2 set pm2-logrotate:retain 14 >/dev/null
env PATH="$PATH:/usr/bin:/usr/local/bin" pm2 startup systemd -u "$APP_USER" --hp "$APP_HOME" >/dev/null
systemctl enable "pm2-$APP_USER" >/dev/null 2>&1 || true

log "Dimensionando PostgreSQL, app Node e kernel conforme a instância"
"$LIB_DIR/tune.sh"

cat > /etc/systemd/system/klinsync-db-tune.service <<EOF
[Unit]
Description=KlinSync DB - reajusta recursos quando o tamanho da EC2 muda
After=network-online.target postgresql.service pm2-$APP_USER.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/klinsync-db-tune --boot

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable klinsync-db-tune.service >/dev/null 2>&1

if [ "$FIREWALL" = ufw ]; then
  log "Firewall (UFW) e fail2ban"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH
  ufw allow from "$BACKEND_PRIVATE_IP" to any port 5432 proto tcp comment 'Postgres <- backend'
  ufw allow from "$BACKEND_PRIVATE_IP" to any port "$DB_APP_PORT" proto tcp comment 'App DB <- backend'
  ufw --force enable
  systemctl enable --now fail2ban
else
  warn "Amazon Linux: não há UFW. No Security Group, libere 5432 e $DB_APP_PORT SOMENTE para o SG/IP do backend."
fi

cat <<EOF

============================================================
 EC2 de DB pronta ($OS_NAME, $INSTANCE_TYPE).

 1) Copie a URL do banco de $CREDENTIALS_FILE para o DATABASE_URL do
    /etc/klinsync/backend.env na EC2 de backend (depois apague o arquivo).
 2) Na EC2 de backend, defina DB_MAX_CONNECTIONS (valor impresso acima) em
    /etc/klinsync/deploy.env e rode: sudo klinsync-tune
 3) Publique migrations/app no S3:  scripts/publish.sh
 4) Aplique e suba a versão:        sudo klinsync-db-deploy
 5) Backup manual:                  sudo klinsync-db-backup
 Se redimensionar a EC2, o ajuste é refeito sozinho no boot (ou rode: sudo klinsync-db-tune).
============================================================
EOF
