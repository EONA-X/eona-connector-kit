#!/usr/bin/env bash
#
# Prepare everything the connector needs before its runtimes start.
#
# Run this once, after editing compose/.env, and again any time you change the
# participant's identity, rotate keys, or lose the bundled dev-mode Vault.
# It is idempotent: nothing already in place is touched.
#
#   1. sanity-check .env (the derived values that compose cannot compute)
#   2. start the bundled PostgreSQL and Vault, if that is what you are using
#   3. generate the participant key pair, if it does not exist
#   4. seed Vault: public key, private key, management API key
#   5. make sure the database exists and the role can run Flyway's DDL
#   6. render config/<service>/config.properties from .env
#   7. write the DID document, for reference or for static publication
#
# It deliberately does NOT start the connectors — bring them up afterwards with
#   docker compose up -d
# or run ../scripts/up.sh, which does bootstrap and start in one go.
#
# Usage: bootstrap.sh [--external-datastores] [--force-keys]
#   --external-datastores  do not start the bundled Postgres/Vault; use the
#                          ones POSTGRES_* / VAULT_URL point at
#   --force-keys           regenerate the key pair and overwrite it in Vault.
#                          Invalidates the published DID document.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

FORCE_KEYS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --external-datastores) EXTERNAL_DATASTORES=1; shift ;;
    --force-keys) FORCE_KEYS=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
export EXTERNAL_DATASTORES="${EXTERNAL_DATASTORES:-0}"

require_cmd docker curl openssl base64 sed awk
docker compose version >/dev/null 2>&1 \
  || die "Docker Compose v2 is required (the 'docker compose' subcommand, not 'docker-compose')"

load_env

# ---------------------------------------------------------------------------
# 1. Check .env for the things compose cannot check for itself
# ---------------------------------------------------------------------------
info "checking ${ENV_FILE#"$KIT_ROOT"/}"

expected_b64="$(b64url_nopad "$PARTICIPANT_DID")"
if [ "${PARTICIPANT_DID_B64:-}" != "$expected_b64" ]; then
  die "PARTICIPANT_DID_B64 does not match PARTICIPANT_DID.
  It is embedded in the DID document's credential-service URL and in every
  Identity API path, so a mismatch breaks credential issuance silently.
  Set it to:
      PARTICIPANT_DID_B64=${expected_b64}"
fi
ok "PARTICIPANT_DID_B64 matches PARTICIPANT_DID"

case "$PARTICIPANT_DID" in
  did:web:*) ;;
  *) die "PARTICIPANT_DID must be a did:web — got '$PARTICIPANT_DID'" ;;
esac

expected_sts_alias="${PARTICIPANT_DID}-sts-client-secret"
if [ "$STS_CLIENT_SECRET_ALIAS" != "$expected_sts_alias" ]; then
  warn "STS_CLIENT_SECRET_ALIAS is '$STS_CLIENT_SECRET_ALIAS' but the identity-hub"
  warn "mints the secret at '$expected_sts_alias'. The control-plane will not find it."
fi

if [ "$AUTHORITY_DID" = "$PARTICIPANT_DID" ]; then
  warn "AUTHORITY_DID is this participant's own DID — standalone evaluation mode."
  warn "Set it to the real dataspace authority before talking to other connectors."
fi

if [ "${DID_WEB_USE_HTTPS:-false}" != "true" ]; then
  warn "DID_WEB_USE_HTTPS=false — did:web resolution over plain http. Local use only."
fi

case "$VAULT_TOKEN" in
  change-me*|root) warn "VAULT_TOKEN is still a placeholder. Fine for a throwaway run, not otherwise." ;;
esac
case "$POSTGRES_PASSWORD" in
  change-me*) warn "POSTGRES_PASSWORD is still a placeholder. Fine for a throwaway run, not otherwise." ;;
esac

# ---------------------------------------------------------------------------
# 1b. Images
# ---------------------------------------------------------------------------
# Only a warning here: bootstrap prepares state and needs no images. up.sh
# refuses to start without them.
info "checking the connector images"
check_connector_images warn || true

# ---------------------------------------------------------------------------
# 2. Datastores
# ---------------------------------------------------------------------------
if [ "$EXTERNAL_DATASTORES" = "1" ]; then
  info "using external datastores (not starting the bundled ones)"
else
  info "starting the bundled PostgreSQL and Vault"
  compose up -d postgres vault
  log "waiting for them to report healthy"
  vault_wait 120 || die "Vault did not come up — check: docker compose logs vault"
  ok "Vault is up at ${VAULT_ADDR_HOST}"
  pg_wait 120 || die "PostgreSQL did not come up — check: docker compose logs postgres"
  ok "PostgreSQL is up"
  warn "the bundled Vault runs in dev mode: in-memory storage, fixed root token, no TLS."
  warn "Everything in it is lost on restart. Never use it for anything real."
fi

# ---------------------------------------------------------------------------
# 3-4. Keys and Vault
# ---------------------------------------------------------------------------
if [ "$FORCE_KEYS" -eq 1 ]; then
  "${SCRIPTS_DIR}/gen-keys.sh" --force
  "${SCRIPTS_DIR}/seed-vault.sh" --force
else
  "${SCRIPTS_DIR}/gen-keys.sh"
  "${SCRIPTS_DIR}/seed-vault.sh"
fi

# ---------------------------------------------------------------------------
# 5. Database
# ---------------------------------------------------------------------------
"${SCRIPTS_DIR}/create-database.sh"

# ---------------------------------------------------------------------------
# 6. Rendered configuration
# ---------------------------------------------------------------------------
info "rendering config.properties from .env"
"${SCRIPTS_DIR}/render-config.sh"

# ---------------------------------------------------------------------------
# 7. DID document
# ---------------------------------------------------------------------------
"${SCRIPTS_DIR}/did-document.sh" >/dev/null
ok "wrote compose/secrets/did.json (see: scripts/did-document.sh, for where it must be served)"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
printf '\n'
info "bootstrap complete — start the connector with:"
if [ "$EXTERNAL_DATASTORES" = "1" ]; then
  printf '    cd %s && docker compose -f compose.yaml -f compose.external-datastores.yaml up -d\n' "${COMPOSE_DIR#"$KIT_ROOT"/}"
else
  printf '    cd %s && docker compose up -d\n' "${COMPOSE_DIR#"$KIT_ROOT"/}"
fi
printf '    scripts/smoke-test.sh\n\n'
log "On the first boot the three runtimes migrate the database together and"
log "wait for each other at the migration barrier, so expect a few minutes"
log "before anything answers. One restart of the data-plane is normal: it"
log "registers against the control-plane and may get there a moment early."
