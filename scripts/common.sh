#!/usr/bin/env bash
# Funções compartilhadas pelos scripts da EC2 de DB. Uso: source "$(dirname "$(readlink -f "$0")")/common.sh"
set -euo pipefail

CONFIG_DIR="/etc/klinsync"
DEPLOY_ENV="$CONFIG_DIR/db-deploy.env"
DB_ENV="$CONFIG_DIR/db.env"
FINGERPRINT_FILE="$CONFIG_DIR/db-sizing.fingerprint"
CREDENTIALS_FILE="/root/klinsync-db-credenciais.txt"
APP_USER="klinsync"
APP_HOME="/home/$APP_USER"
LIB_DIR="/usr/local/lib/klinsync-db"

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[aviso]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[erro]\033[0m $*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "Rode como root (sudo)."; }

# ------------------------------- Sistema operacional ------------------------------
# Define OS_ID, OS_VERSION, OS_NAME, ARCH, PKG (apt|dnf) e FIREWALL (ufw|none).
detect_os() {
  [ -r /etc/os-release ] || die "Não foi possível identificar o sistema (/etc/os-release ausente)."
  OS_ID="$(. /etc/os-release && echo "${ID:-desconhecido}")"
  OS_VERSION="$(. /etc/os-release && echo "${VERSION_ID:-?}")"
  OS_NAME="$(. /etc/os-release && echo "${PRETTY_NAME:-$OS_ID $OS_VERSION}")"
  ARCH="$(uname -m)"

  case "$OS_ID" in
    ubuntu)
      PKG=apt; FIREWALL=ufw
      case "$OS_VERSION" in 22.04|24.04) ;; *) warn "Ubuntu $OS_VERSION não foi testado (suportados: 22.04 e 24.04)." ;; esac
      ;;
    debian)
      PKG=apt; FIREWALL=ufw
      case "$OS_VERSION" in 12|13) ;; *) warn "Debian $OS_VERSION não foi testado (suportados: 12 e 13)." ;; esac
      ;;
    amzn)
      case "$OS_VERSION" in
        2023*) PKG=dnf; FIREWALL=none ;;
        *) die "Amazon Linux $OS_VERSION não é suportado (Node 22 exige glibc >= 2.28). Use Amazon Linux 2023 ou Ubuntu 22.04/24.04." ;;
      esac
      ;;
    *) die "Sistema '$OS_NAME' não suportado. Suportados: Ubuntu 22.04/24.04, Debian 12/13 e Amazon Linux 2023." ;;
  esac

  case "$ARCH" in x86_64|aarch64) ;; *) die "Arquitetura $ARCH não suportada (use x86_64 ou aarch64/Graviton)." ;; esac
  command -v systemctl >/dev/null 2>&1 || die "systemd é obrigatório."
}

pkg_install() {
  if [ "$PKG" = apt ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  else
    dnf install -y "$@"
  fi
}

# --------------------------------- Recursos da EC2 --------------------------------
# Consulta o metadata da EC2 (IMDSv2). Uso: imds meta-data/instance-type
imds() {
  local token
  token="$(curl -fsS --max-time 2 -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)" || return 1
  curl -fsS --max-time 2 -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/$1"
}

# Define CPU_COUNT, MEM_MB, SWAP_MB, DISK_FREE_MB e INSTANCE_TYPE.
detect_resources() {
  CPU_COUNT="$(nproc)"
  MEM_MB="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
  SWAP_MB="$(awk '/^SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
  DISK_FREE_MB="$(df -Pm / | awk 'NR==2 {print $4}')"
  INSTANCE_TYPE="$(imds meta-data/instance-type 2>/dev/null || echo desconhecido)"
}

sizing_fingerprint() { echo "$INSTANCE_TYPE:$CPU_COUNT:$MEM_MB"; }

clamp() { # clamp VALOR MIN MAX
  local v="$1" lo="$2" hi="$3"
  [ "$v" -lt "$lo" ] && v="$lo"
  [ "$v" -gt "$hi" ] && v="$hi"
  echo "$v"
}

# Memória deixada para o sistema operacional, conforme o tamanho da máquina.
os_reserve_mb() {
  if   [ "$MEM_MB" -lt 1536 ]; then echo 256
  elif [ "$MEM_MB" -lt 4096 ]; then echo 512
  elif [ "$MEM_MB" -lt 8192 ]; then echo 768
  else echo 1024
  fi
}

# Valida o tamanho da instância. Uso: validate_size backend|db
# Mínimo para rodar: ~1 GiB de RAM e 5 GB livres (db). Recomendado: 2 vCPU e 2 GiB.
# FORCE_SIZE=1 ignora o mínimo (não recomendado).
validate_size() {
  local role="$1" min_mem=700 min_disk=3000 rec_mem=1900 rec_cpu=2
  [ "$role" = db ] && min_disk=5000

  echo "Instância: $INSTANCE_TYPE | SO: $OS_NAME ($ARCH) | vCPU: $CPU_COUNT | RAM: ${MEM_MB} MB | swap: ${SWAP_MB} MB | disco livre: ${DISK_FREE_MB} MB"

  if [ "$MEM_MB" -lt "$min_mem" ] || [ "$DISK_FREE_MB" -lt "$min_disk" ]; then
    if [ "${FORCE_SIZE:-0}" = "1" ]; then
      warn "Instância abaixo do mínimo (RAM >= ${min_mem} MB, disco livre >= ${min_disk} MB), seguindo por FORCE_SIZE=1."
    else
      die "Instância pequena demais para a EC2 de $role (RAM >= ${min_mem} MB e disco livre >= ${min_disk} MB). Use t3.micro/t4g.micro ou maior, ou FORCE_SIZE=1 para ignorar."
    fi
  fi
  [ "$MEM_MB" -ge "$rec_mem" ] || warn "RAM abaixo do recomendado (${rec_mem} MB). Funciona, mas com pouca folga: prefira t3.small ou maior."
  [ "$CPU_COUNT" -ge "$rec_cpu" ] || warn "Apenas $CPU_COUNT vCPU (recomendado: $rec_cpu ou mais)."
}

# Cria swap em instâncias com pouca RAM (evita OOM no npm ci/build e em picos).
ensure_swap() {
  [ "$MEM_MB" -lt 2048 ] || return 0
  [ "$SWAP_MB" -eq 0 ] || return 0
  [ ! -e /swapfile ] || return 0
  local size_mb
  size_mb="$(clamp $((MEM_MB * 2)) 1024 4096)"
  if [ "$DISK_FREE_MB" -lt $((size_mb + 2048)) ]; then
    warn "Sem espaço em disco suficiente para criar swap de ${size_mb} MB."
    return 0
  fi
  log "Criando swap de ${size_mb} MB (RAM de ${MEM_MB} MB)"
  fallocate -l "${size_mb}M" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  SWAP_MB="$size_mb"
}

# Define/atualiza CHAVE=valor em um arquivo de ambiente, preservando as demais linhas.
set_kv() { # set_kv ARQUIVO CHAVE VALOR
  local f="$1" k="$2" v="$3"
  touch "$f"
  if grep -q "^$k=" "$f"; then sed -i "s|^$k=.*|$k=$v|" "$f"; else echo "$k=$v" >> "$f"; fi
}

load_deploy_env() {
  [ -f "$DEPLOY_ENV" ] || die "$DEPLOY_ENV não existe. Rode scripts/setup-ec2.sh primeiro."
  set -a
  # shellcheck disable=SC1090
  . "$DEPLOY_ENV"
  set +a
}

# Executa um comando como o usuário da aplicação (dono do PM2).
# O diretório de trabalho é APP_CWD (padrão: home do usuário), pois o cwd do root não é legível pelo app.
as_app() { ( cd "${APP_CWD:-$APP_HOME}" && runuser -u "$APP_USER" -- env HOME="$APP_HOME" PM2_HOME="$APP_HOME/.pm2" "$@" ); }

# psql como superusuário do Postgres (autenticação peer, socket local).
psql_admin() { (cd /tmp && runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 "$@"); }

health_check() {
  local url="$1" tries="${2:-30}"
  for _ in $(seq 1 "$tries"); do
    if curl -fsS -o /dev/null --max-time 3 "$url"; then return 0; fi
    sleep 1
  done
  return 1
}

# Separa as roles do banco (idempotente; usa DB_NAME e DB_USER do deploy.env):
#   klinsync_owner  dono do banco e dos objetos; sem login (NOLOGIN). O migrate.sh a assume com SET ROLE.
#   $DB_USER        role da API (klinsync_app): só DML, sem DDL. Os privilégios por tabela vêm das migrations;
#                   as default privileges abaixo cobrem as tabelas criadas por migrations futuras.
DB_OWNER_ROLE="${DB_OWNER_ROLE:-klinsync_owner}"
ensure_db_roles() {
  DB_USER="${DB_USER:-klinsync_app}"
  psql_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_OWNER_ROLE'" | grep -q 1 \
    || psql_admin -c "CREATE ROLE $DB_OWNER_ROLE NOLOGIN"
  psql_admin -d "$DB_NAME" -v owner="$DB_OWNER_ROLE" -v app="$DB_USER" -v db="$DB_NAME" <<'SQL'
ALTER DATABASE :"db" OWNER TO :"owner";
GRANT CONNECT ON DATABASE :"db" TO :"app";
REASSIGN OWNED BY :"app" TO :"owner";
ALTER SCHEMA public OWNER TO :"owner";
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM :"app";
GRANT USAGE ON SCHEMA public TO :"app";
ALTER ROLE :"app" NOSUPERUSER NOCREATEDB NOCREATEROLE;
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO :"app";
SQL
}

# psql como superusuário do Postgres, já assumindo a role dona dos objetos (para DDL/carga de dados).
# O SQL vai por stdin: o arquivo pode estar em /root, ilegível para o usuário postgres.
psql_como_dono() { psql_admin -d "$DB_NAME" -c "SET ROLE $DB_OWNER_ROLE" "$@"; }
