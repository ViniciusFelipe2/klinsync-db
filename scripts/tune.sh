#!/usr/bin/env bash
# =============================================================================
# KlinSync DB — ajusta PostgreSQL, app Node (PM2) e kernel ao tamanho (vCPU/RAM) desta EC2.
#
#   sudo klinsync-db-tune           # recalcula e aplica agora
#   sudo klinsync-db-tune --boot    # chamado no boot: só reaplica se o tamanho da instância mudou
#
# Rode de novo (ou apenas reinicie) depois de redimensionar a instância (stop/start com outro tipo).
# Reserva: memória do SO + orçamento do app Node (10% da RAM, entre 128 e 512 MB); o resto é do Postgres.
#   shared_buffers        25% da RAM do Postgres          effective_cache_size  70% da RAM total
#   max_connections       RAM do Postgres / 8 (40..200)   work_mem              (RAM - shared) / (conexões*3)
#   maintenance_work_mem  RAM / 16 (32..2048 MB)          paralelismo           conforme vCPU
# O Postgres só é reiniciado se algum parâmetro novo exigir (shared_buffers, max_connections...).
# Informe o max_connections no backend (DB_MAX_CONNECTIONS em /etc/klinsync/deploy.env).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

require_root
load_deploy_env
BOOT=0; [ "${1:-}" = "--boot" ] && BOOT=1

detect_os
detect_resources
FP="$(sizing_fingerprint)"
if [ "$BOOT" = 1 ] && [ -f "$FINGERPRINT_FILE" ] && [ "$(cat "$FINGERPRINT_FILE")" = "$FP" ]; then
  echo "klinsync-db-tune: tamanho da instância inalterado ($FP). Nada a fazer."
  exit 0
fi

log "Dimensionando para a instância $INSTANCE_TYPE"
validate_size db
ensure_swap

# ------------------------------- Cálculo de recursos ------------------------------
OS_RES="$(os_reserve_mb)"
APP_BUDGET_MB="$(clamp $((MEM_MB * 10 / 100)) 128 512)"
PG_RAM_MB=$(( MEM_MB - OS_RES - APP_BUDGET_MB ))
[ "$PG_RAM_MB" -ge 128 ] || PG_RAM_MB=128

SHARED_MB="$(clamp $((PG_RAM_MB * 25 / 100)) 64 16384)"
CACHE_MB=$(( (MEM_MB - OS_RES) * 70 / 100 ))
MAX_CONN="$(clamp $((PG_RAM_MB / 8)) 40 200)"
MAINT_MB="$(clamp $((MEM_MB / 16)) 32 2048)"
WORK_KB="$(clamp $(( (PG_RAM_MB - SHARED_MB) * 1024 / (MAX_CONN * 3) )) 1024 65536)"
WAL_BUF_MB="$(clamp $((SHARED_MB * 3 / 100)) 4 16)"
if   [ "$MEM_MB" -lt 2048 ]; then MIN_WAL=256;  MAX_WAL=1024
elif [ "$MEM_MB" -lt 8192 ]; then MIN_WAL=1024; MAX_WAL=2048
else MIN_WAL=1024; MAX_WAL=4096; fi

WORKER_PROCS="$(clamp "$CPU_COUNT" 4 32)"
PAR_GATHER=0
if [ "$CPU_COUNT" -ge 2 ]; then PAR_GATHER="$(clamp $((CPU_COUNT / 2)) 1 4)"; fi
PAR_MAINT="$(clamp $((CPU_COUNT / 2)) 1 4)"
AUTOVAC="$(clamp "$CPU_COUNT" 3 6)"

APP_HEAP_MB="$(clamp $((APP_BUDGET_MB * 70 / 100)) 96 4096)"
APP_RESTART_MB="$(clamp "$APP_BUDGET_MB" $((APP_HEAP_MB + 32)) 8192)"

# ----------------------------------- PostgreSQL ----------------------------------
log "PostgreSQL: shared_buffers ${SHARED_MB} MB | max_connections $MAX_CONN | work_mem ${WORK_KB} kB"
psql_admin <<SQL
ALTER SYSTEM SET shared_buffers = '${SHARED_MB}MB';
ALTER SYSTEM SET effective_cache_size = '${CACHE_MB}MB';
ALTER SYSTEM SET maintenance_work_mem = '${MAINT_MB}MB';
ALTER SYSTEM SET work_mem = '${WORK_KB}kB';
ALTER SYSTEM SET max_connections = ${MAX_CONN};
ALTER SYSTEM SET wal_buffers = '${WAL_BUF_MB}MB';
ALTER SYSTEM SET min_wal_size = '${MIN_WAL}MB';
ALTER SYSTEM SET max_wal_size = '${MAX_WAL}MB';
ALTER SYSTEM SET checkpoint_completion_target = 0.9;
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_io_concurrency = 200;
ALTER SYSTEM SET max_worker_processes = ${WORKER_PROCS};
ALTER SYSTEM SET max_parallel_workers = ${WORKER_PROCS};
ALTER SYSTEM SET max_parallel_workers_per_gather = ${PAR_GATHER};
ALTER SYSTEM SET max_parallel_maintenance_workers = ${PAR_MAINT};
ALTER SYSTEM SET autovacuum_max_workers = ${AUTOVAC};
SELECT pg_reload_conf();
SQL
sleep 1
PENDING="$(psql_admin -tAc "SELECT count(*) FROM pg_settings WHERE pending_restart" | tr -d '[:space:]')"
if [ "${PENDING:-0}" -gt 0 ]; then
  log "Reiniciando o PostgreSQL ($PENDING parâmetro(s) exigem reinício; conexões caem por alguns segundos)"
  systemctl restart postgresql
else
  echo "Nenhum parâmetro exige reinício do PostgreSQL."
fi

# -------------------------------------- Kernel -----------------------------------
cat > /etc/sysctl.d/99-klinsync-db.conf <<EOF
# Gerado por scripts/tune.sh
vm.swappiness = 10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
EOF
sysctl --system >/dev/null

# ------------------------------- App Node (PM2) ----------------------------------
log "PM2: heap ${APP_HEAP_MB} MB | reinício em ${APP_RESTART_MB} MB"
cat > "$APP_DIR/ecosystem.config.cjs" <<EOF
// Gerado por scripts/tune.sh para $INSTANCE_TYPE (${CPU_COUNT} vCPU, ${MEM_MB} MB). Não edite: rode klinsync-db-tune.
// Variáveis vindas de $DB_ENV (node --env-file).
module.exports = {
  apps: [
    {
      name: "$PM2_APP_NAME",
      cwd: "$APP_DIR/current",
      script: "$DB_APP_ENTRY",
      node_args: ["--env-file=$DB_ENV", "--max-old-space-size=$APP_HEAP_MB"],
      exec_mode: "fork",
      instances: 1,
      autorestart: true,
      max_memory_restart: "${APP_RESTART_MB}M",
      kill_timeout: 10000,
      time: true,
    },
  ],
};
EOF
chown "$APP_USER:$APP_USER" "$APP_DIR/ecosystem.config.cjs"

BUILD_HEAP_MB="$(clamp $((MEM_MB * 60 / 100)) 384 4096)"
set_kv "$DEPLOY_ENV" INSTANCE_TYPE "$INSTANCE_TYPE"
set_kv "$DEPLOY_ENV" CPU_COUNT "$CPU_COUNT"
set_kv "$DEPLOY_ENV" MEM_MB "$MEM_MB"
set_kv "$DEPLOY_ENV" PG_MAX_CONNECTIONS "$MAX_CONN"
set_kv "$DEPLOY_ENV" BUILD_HEAP_MB "$BUILD_HEAP_MB"

if [ -L "$APP_DIR/current" ] && [ -f "$APP_DIR/current/$DB_APP_ENTRY" ]; then
  as_app pm2 startOrReload "$APP_DIR/ecosystem.config.cjs" --update-env
  as_app pm2 save >/dev/null
fi

if [ -f "$CREDENTIALS_FILE" ]; then set_kv "$CREDENTIALS_FILE" DB_MAX_CONNECTIONS "$MAX_CONN"; fi
echo "$FP" > "$FINGERPRINT_FILE"

cat <<EOF

------------------------------------------------------------
 Dimensionamento aplicado ($INSTANCE_TYPE: ${CPU_COUNT} vCPU, ${MEM_MB} MB)
   Postgres: shared_buffers ${SHARED_MB} MB | effective_cache_size ${CACHE_MB} MB
             max_connections $MAX_CONN | work_mem ${WORK_KB} kB | maintenance_work_mem ${MAINT_MB} MB
             workers: $WORKER_PROCS (paralelos por consulta: $PAR_GATHER)
   App Node: heap ${APP_HEAP_MB} MB (reinício em ${APP_RESTART_MB} MB)
 No backend, defina DB_MAX_CONNECTIONS=$MAX_CONN em /etc/klinsync/deploy.env e rode: sudo klinsync-tune
------------------------------------------------------------
EOF
