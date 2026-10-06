#!/usr/bin/env bash
# =============================================================================
# KlinSync DB — backup do banco (pg_dump formato custom) com retenção local e cópia opcional no S3.
# Roda diariamente às 03:00 (cron instalado pelo setup-ec2.sh). Manual: sudo klinsync-db-backup
# Para enviar ao S3, a role da EC2 precisa de s3:PutObject em <bucket>/backups/*.
# Restaurar: pg_restore -d klinsync --clean --if-exists arquivo.dump
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

require_root
load_deploy_env

DEST="/var/backups/klinsync"
FILE="$DEST/${DB_NAME}-$(date +%F-%H%M).dump"
mkdir -p "$DEST"
chmod 700 "$DEST"

log "Gerando $FILE"
(cd /tmp && runuser -u postgres -- pg_dump -Fc "$DB_NAME") > "$FILE"
chmod 600 "$FILE"

if [ "${BACKUP_TO_S3:-1}" = "1" ]; then
  if aws s3 cp "$FILE" "s3://$DB_BUCKET/backups/$(basename "$FILE")" --only-show-errors; then
    echo "Cópia enviada para s3://$DB_BUCKET/backups/"
  else
    warn "Não foi possível enviar o backup ao S3 (verifique a permissão da role)."
  fi
fi

find "$DEST" -type f -name '*.dump' -mtime +"${BACKUP_RETENTION_DAYS:-14}" -delete
log "Backup concluído."
