#!/usr/bin/env bash
#
# Bring the whole connector up from nothing, in the right order.
#
#   bootstrap (datastores, keys, Vault, database, config)
#   then start the three runtimes
#   then verify
#
# The ordering matters in one place only: Vault must already hold the
# participant public key when the identity-hub starts, or that runtime refuses
# to boot. Everything else sorts itself out — see the START-UP ORDERING note at
# the top of compose/compose.yaml for why the three runtimes start together
# rather than in a chain.
#
# Safe to re-run. Nothing already in place is regenerated.
#
# Usage: up.sh [--external-datastores] [--no-smoke-test]
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SMOKE=1
BOOTSTRAP_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --external-datastores) EXTERNAL_DATASTORES=1; BOOTSTRAP_ARGS+=(--external-datastores); shift ;;
    --no-smoke-test) SMOKE=0; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
export EXTERNAL_DATASTORES="${EXTERNAL_DATASTORES:-0}"

if [ ! -f "$ENV_FILE" ]; then
  die "no compose/.env yet.
  cp compose/.env.example compose/.env
then edit it — at minimum POSTGRES_PASSWORD and VAULT_TOKEN — and run this again."
fi

KIT_CALLED_BY_UP=1 "${SCRIPTS_DIR}/bootstrap.sh" ${BOOTSTRAP_ARGS[@]+"${BOOTSTRAP_ARGS[@]}"}

info "checking the connector images"
check_connector_images fatal

info "starting the connector runtimes"
compose up -d

printf '\n'
log "the three runtimes are migrating the database and waiting for each other"
log "at the migration barrier; the first boot takes a few minutes"
log "(the data-plane may restart once meanwhile; that is fine, a loop is not)"
printf '\n'

if [ "$SMOKE" -eq 1 ]; then
  "${SCRIPTS_DIR}/smoke-test.sh"
else
  info "started. Verify with: scripts/smoke-test.sh"
fi
