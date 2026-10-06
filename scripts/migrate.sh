#!/usr/bin/env bash
# =============================================================================
# KlinSync DB — aplica migrations/*.sql pendentes, em ordem alfabética.
#
#   sudo klinsync-db-migrate                      # usa /opt/klinsync-db/current/migrations
#   sudo klinsync-db-migrate /caminho/migrations  # pasta específica
#
# Cada arquivo roda numa transação própria e é registrado em public.schema_migrations
# com o checksum. Um arquivo já aplicado que foi alterado depois interrompe a execução
# (crie uma nova migration em vez de editar uma antiga).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

require_root
load_deploy_env

DIR="${1:-$APP_DIR/current/migrations}"
if [ ! -d "$DIR" ]; then
  warn "Pasta de migrations não encontrada: $DIR (nada a aplicar)."
  exit 0
fi

[ -f "$DB_ENV" ] || die "$DB_ENV não existe."
set -a
# shellcheck disable=SC1090
. "$DB_ENV"
set +a

exec 8>/var/lock/klinsync-db-migrate.lock
flock -n 8 || die "Outra migração está em andamento."

PSQL=(psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1)
"${PSQL[@]}" -c "CREATE TABLE IF NOT EXISTS public.schema_migrations (
  filename   text PRIMARY KEY,
  checksum   text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now())"

APPLIED=0
while IFS= read -r f; do
  name="$(basename "$f")"
  sum="$(sha256sum "$f" | cut -d' ' -f1)"
  prev="$("${PSQL[@]}" -tA -c "SELECT checksum FROM public.schema_migrations WHERE filename = '$name'")"
  if [ -n "$prev" ]; then
    [ "$prev" = "$sum" ] || die "A migration '$name' já foi aplicada e o arquivo foi alterado. Crie uma nova migration."
    continue
  fi
  log "Aplicando $name"
  "${PSQL[@]}" --single-transaction -f "$f" \
    -c "INSERT INTO public.schema_migrations (filename, checksum) VALUES ('$name', '$sum')"
  APPLIED=$((APPLIED + 1))
done < <(find "$DIR" -maxdepth 1 -type f -name '*.sql' | sort)

echo "Migrations aplicadas nesta execução: $APPLIED"
