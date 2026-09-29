#!/usr/bin/env bash
#
# Load the secrets the connector needs into HashiCorp Vault.
#
# What has to be there before the runtimes boot, and why:
#
#   <VAULT_ALIAS_PUBLIC_KEY>   the public key, PEM.  HARD BOOT GATE: the
#                              identity-hub reads it while creating the
#                              participant context and throws if it is missing,
#                              so the runtime will not start.
#   <VAULT_ALIAS_PRIVATE_KEY>  the private key, PEM. Not checked at boot; the
#                              first attempt to sign anything fails without it.
#   <MANAGEMENT_API_KEY_ALIAS> the management API bearer token, generated here
#                              if absent. Only when MANAGEMENT_API_AUTH_ENABLED.
#
# One secret is NOT seeded here and cannot be: the STS client secret at
# "<did>-sts-client-secret". The identity-hub mints it itself when it creates
# the participant context on its first successful boot. That is why a fresh
# install has an inherent order — seed keys, boot the identity-hub, and only
# then can the control-plane obtain a token.
#
# Writes use KV v2 with the value in a field called "content", which is what
# EDC reads. The effective path is
#   <VAULT_SECRET_PATH>/data/[<VAULT_FOLDER>/]<alias>
# so VAULT_SECRET_PATH and VAULT_FOLDER here must match what the runtimes are
# configured with, or an alias that exists will still not resolve.
#
# Idempotent: an alias that already exists is left as it is, so re-running never
# rotates a live key. --force overwrites (KV v2 keeps the old version).
#
# Usage: seed-vault.sh [--force]
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

require_cmd curl openssl
load_env

PRIVATE_PEM="${SECRETS_DIR}/${VAULT_ALIAS_PRIVATE_KEY}.pem"
PUBLIC_PEM="${SECRETS_DIR}/${VAULT_ALIAS_PUBLIC_KEY}.pem"

[ -f "$PRIVATE_PEM" ] || die "no private key at compose/secrets/$(basename "$PRIVATE_PEM") — run gen-keys.sh first"
[ -f "$PUBLIC_PEM" ]  || die "no public key at compose/secrets/$(basename "$PUBLIC_PEM") — run gen-keys.sh first"

info "seeding Vault at ${VAULT_ADDR_HOST}"

vault_up || die "Vault is not answering at ${VAULT_ADDR_HOST}
  bundled: start it with   docker compose up -d vault
  external: check VAULT_URL / VAULT_ADDR_HOST in $ENV_FILE"

# Fail early and clearly on a bad token rather than on every individual write.
# The token goes in through a 0600 curl config file, never argv — see
# secret_curl in lib/common.sh.
_vault_token_cfg | secret_curl -fsS -o /dev/null --max-time 10 \
  "${VAULT_ADDR_HOST}/v1/auth/token/lookup-self" \
  || die "Vault rejected VAULT_TOKEN — check it in $ENV_FILE"

put() {
  local alias="$1" value="$2"
  if [ "$FORCE" -eq 1 ]; then
    vault_put "$alias" "$value" || die "vault: could not write $alias"
    ok "vault: wrote $alias (forced)"
  else
    vault_put_if_absent "$alias" "$value"
  fi
}

put "$VAULT_ALIAS_PUBLIC_KEY"  "$(cat "$PUBLIC_PEM")"
put "$VAULT_ALIAS_PRIVATE_KEY" "$(cat "$PRIVATE_PEM")"

if [ "$MANAGEMENT_API_AUTH_ENABLED" = "true" ]; then
  KEY_FILE="${SECRETS_DIR}/management-api-key.txt"
  if vault_has "$MANAGEMENT_API_KEY_ALIAS" && [ "$FORCE" -eq 0 ]; then
    log "vault: $MANAGEMENT_API_KEY_ALIAS already present, leaving it alone"
    # Keep the local copy in step so the smoke test and your own clients can
    # read the key without going to Vault.
    if existing="$(vault_get "$MANAGEMENT_API_KEY_ALIAS")" && [ -n "$existing" ]; then
      printf '%s\n' "$existing" > "$KEY_FILE"
      chmod 0600 "$KEY_FILE"
    fi
  else
    api_key="$(openssl rand -hex 32)"
    vault_put "$MANAGEMENT_API_KEY_ALIAS" "$api_key" || die "vault: could not write $MANAGEMENT_API_KEY_ALIAS"
    printf '%s\n' "$api_key" > "$KEY_FILE"
    chmod 0600 "$KEY_FILE"
    ok "vault: wrote $MANAGEMENT_API_KEY_ALIAS"
    log "a copy is in compose/secrets/management-api-key.txt (mode 600)"
  fi
else
  warn "MANAGEMENT_API_AUTH_ENABLED=false — the management API will accept any caller"
fi

# Informational: this is the one the identity-hub owns.
if vault_has "$STS_CLIENT_SECRET_ALIAS"; then
  ok "vault: STS client secret present (minted by the identity-hub)"
else
  log "vault: STS client secret not present yet — the identity-hub mints it on its first boot"
fi

ok "Vault seeded"
