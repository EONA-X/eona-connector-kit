#!/usr/bin/env bash
#
# Stop the connector.
#
# By default it stops and removes the containers and leaves every byte of state
# alone, so `scripts/up.sh` brings the same connector back.
#
#   --volumes  also delete the PostgreSQL and Vault volumes. This destroys the
#              participant context, every credential it holds, and every
#              contract and agreement. The key pair in compose/secrets/ is kept,
#              so the next bootstrap re-seeds Vault with the SAME keys and the
#              published DID document stays valid.
#
#   --keys     also delete compose/secrets/. The participant's identity is gone:
#              a new key pair means a new DID document, which every
#              counterparty must re-resolve and the authority must re-attest.
#
# Usage: teardown.sh [--volumes] [--keys] [--external-datastores] [--yes]
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

DROP_VOLUMES=0; DROP_KEYS=0; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --volumes) DROP_VOLUMES=1; shift ;;
    --keys) DROP_KEYS=1; shift ;;
    --external-datastores) EXTERNAL_DATASTORES=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
export EXTERNAL_DATASTORES="${EXTERNAL_DATASTORES:-0}"

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  printf '%s [y/N] ' "$1"
  read -r reply
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

if [ "$DROP_VOLUMES" -eq 1 ]; then
  warn "--volumes will delete the database and the Vault volume."
  warn "The participant context and every credential in it are destroyed."
  confirm "Continue?" || die "aborted"
fi

if [ "$DROP_VOLUMES" -eq 1 ]; then
  compose down --volumes --remove-orphans
  ok "containers and volumes removed"
else
  compose down --remove-orphans
  ok "containers removed; volumes kept"
fi

if [ "$DROP_KEYS" -eq 1 ]; then
  warn "--keys will delete compose/secrets/, including the participant private key."
  warn "The DID document becomes unverifiable and has to be reissued and re-attested."
  if confirm "Continue?"; then
    rm -rf "$SECRETS_DIR"
    ok "compose/secrets/ removed"
  else
    log "keys kept"
  fi
fi
