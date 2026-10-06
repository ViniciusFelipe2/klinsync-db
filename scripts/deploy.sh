#!/usr/bin/env bash
# =============================================================================
# KlinSync DB — baixa uma release do S3, aplica as migrations e (se houver) atualiza o app Node no PM2.
#
#   sudo klinsync-db-deploy                       # usa s3://<bucket>/releases/latest.txt
#   sudo klinsync-db-deploy releases/<arquivo>    # versão específica
#
# Formato da release: .tar.gz com migrations/*.sql na raiz e, opcionalmente, um app Node
# (package.json + código). Sem app Node (ou sem DB_APP_ENTRY), só as migrations são aplicadas.
# Ordem: migrations ANTES de trocar o app. Se o app não responder, volta ao app anterior
# (migrations não são revertidas: escreva-as de forma compatível com a versão anterior).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

require_root
load_deploy_env

exec 9>/var/lock/klinsync-db-deploy.lock
flock -n 9 || die "Já existe um deploy em andamento."

KEY="${1:-}"
if [ -z "$KEY" ]; then
  log "Lendo s3://$DB_BUCKET/releases/latest.txt"
  KEY="$(aws s3 cp "s3://$DB_BUCKET/releases/latest.txt" - | tr -d '[:space:]')"
fi
[ -n "$KEY" ] || die "Não foi possível determinar a release."

if [ -f "$APP_DIR/CURRENT_KEY" ] && [ "$(cat "$APP_DIR/CURRENT_KEY")" = "$KEY" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "A release $KEY já está em produção. Use FORCE=1 para reaplicar."
  exit 0
fi

PREV="$(readlink -f "$APP_DIR/current" 2>/dev/null || true)"
REL="$APP_DIR/releases/$(date +%Y%m%d%H%M%S)"

log "Baixando s3://$DB_BUCKET/$KEY"
mkdir -p "$REL"
aws s3 cp "s3://$DB_BUCKET/$KEY" /tmp/klinsync-db-release.tar.gz
tar -xzf /tmp/klinsync-db-release.tar.gz -C "$REL"
rm -f /tmp/klinsync-db-release.tar.gz
chown -R "$APP_USER:$APP_USER" "$REL"

log "Aplicando migrations"
if ! "$SCRIPT_DIR/migrate.sh" "$REL/migrations"; then
  rm -rf "$REL"
  die "Falha nas migrations. A release não foi ativada."
fi

HAS_APP=0
if [ -f "$REL/package.json" ]; then
  log "Instalando dependências e compilando o app Node"
  export APP_CWD="$REL"
  if [ -f package-lock.json ]; then as_app npm ci --no-audit --no-fund; else as_app npm install --no-audit --no-fund; fi
  as_app env NODE_OPTIONS="--max-old-space-size=${BUILD_HEAP_MB:-1024}" npm run build --if-present
  as_app npm prune --omit=dev --no-audit --no-fund
  unset APP_CWD
  [ -f "$REL/$DB_APP_ENTRY" ] && HAS_APP=1 || warn "Entrada '$DB_APP_ENTRY' não existe na release: app Node não será iniciado."
fi

log "Ativando a nova release"
ln -sfn "$REL" "$APP_DIR/current"

if [ "$HAS_APP" = "1" ]; then
  as_app pm2 startOrReload "$APP_DIR/ecosystem.config.cjs" --update-env
  as_app pm2 save >/dev/null
  if ! health_check "http://127.0.0.1:$DB_APP_PORT$DB_APP_HEALTH_PATH" 40; then
    warn "O app do DB não respondeu em $DB_APP_HEALTH_PATH. Voltando ao app anterior."
    if [ -n "$PREV" ] && [ -d "$PREV" ]; then
      ln -sfn "$PREV" "$APP_DIR/current"
      as_app pm2 startOrReload "$APP_DIR/ecosystem.config.cjs" --update-env
      as_app pm2 save >/dev/null
    else
      as_app pm2 stop "$PM2_APP_NAME" || true
    fi
    as_app pm2 logs "$PM2_APP_NAME" --lines 30 --nostream || true
    die "Deploy de $KEY falhou no app (migrations já aplicadas permanecem)."
  fi
else
  as_app pm2 delete "$PM2_APP_NAME" >/dev/null 2>&1 || true
  as_app pm2 save >/dev/null
fi

echo "$KEY" > "$APP_DIR/CURRENT_KEY"

log "Limpando releases antigas (mantém ${KEEP_RELEASES:-5})"
ls -1dt "$APP_DIR"/releases/*/ 2>/dev/null | tail -n +"$(( ${KEEP_RELEASES:-5} + 1 ))" | while read -r old; do
  [ "$(readlink -f "$old")" = "$(readlink -f "$APP_DIR/current")" ] || rm -rf "$old"
done

log "Deploy concluído: $KEY"
