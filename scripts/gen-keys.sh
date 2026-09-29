#!/usr/bin/env bash
#
# Generate the participant's signing key pair.
#
# One elliptic-curve key pair serves the whole connector:
#   - the identity-hub signs STS tokens and DID proofs with it, and publishes
#     the public half in the DID document as verification method "<did>#my-key";
#   - the data-plane signs and verifies transfer-proxy access tokens with it.
#
# The keys are written to compose/secrets/ and loaded into Vault by
# seed-vault.sh. Keeping a copy on disk is what makes the bundled dev-mode
# Vault survivable: when it restarts and forgets everything, bootstrap.sh can
# put the SAME keys back, so the DID document counterparties already fetched
# stays valid.
#
# Idempotent: existing keys are left alone. Use --force to replace them, which
# invalidates the published DID document and every signature made with the old
# key — you then have to republish the DID document and, in a real dataspace,
# re-obtain your credentials.
#
# Usage: gen-keys.sh [--force]
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

require_cmd openssl
load_env

mkdir -p "$SECRETS_DIR"
chmod 0700 "$SECRETS_DIR"

PRIVATE_PEM="${SECRETS_DIR}/${VAULT_ALIAS_PRIVATE_KEY}.pem"
PUBLIC_PEM="${SECRETS_DIR}/${VAULT_ALIAS_PUBLIC_KEY}.pem"

if [ -f "$PRIVATE_PEM" ] && [ -f "$PUBLIC_PEM" ] && [ "$FORCE" -eq 0 ]; then
  ok "key pair already present in compose/secrets/ — reusing it"
  log "private: $(basename "$PRIVATE_PEM")   public: $(basename "$PUBLIC_PEM")"
  log "pass --force to replace it (this invalidates the published DID document)"
  exit 0
fi

if [ "$FORCE" -eq 1 ] && [ -f "$PRIVATE_PEM" ]; then
  warn "--force: replacing the existing key pair"
  warn "the DID document must be republished and Vault re-seeded (seed-vault.sh --force)"
fi

info "generating a ${KEY_CURVE} key pair"

tmp_sec1="$(mktemp)"
trap 'rm -f "$tmp_sec1"' EXIT

openssl ecparam -name "$KEY_CURVE" -genkey -noout -out "$tmp_sec1" 2>/dev/null \
  || die "openssl could not generate a key on curve '$KEY_CURVE' (try: openssl ecparam -list_curves)"

# PKCS#8 for the private half: the form every EDC key parser accepts.
openssl pkcs8 -topk8 -nocrypt -in "$tmp_sec1" -out "$PRIVATE_PEM"
# SubjectPublicKeyInfo for the public half: what the identity-hub stores as the
# participant context's publicKeyPem and converts into the DID document's JWK.
openssl ec -in "$tmp_sec1" -pubout -out "$PUBLIC_PEM" 2>/dev/null

chmod 0600 "$PRIVATE_PEM"
chmod 0644 "$PUBLIC_PEM"

ok "wrote compose/secrets/$(basename "$PRIVATE_PEM") (private, mode 600)"
ok "wrote compose/secrets/$(basename "$PUBLIC_PEM") (public)"
log "these are not loaded into Vault yet — seed-vault.sh does that"
