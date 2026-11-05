#!/usr/bin/env bash
#
# Build the participant's did:web document from the generated public key.
#
# The identity-hub serves this document itself on its DID API (port 8383, base
# path /api/did), so for the default in-network DID you do not have to publish
# anything: nothing else has to resolve it. This script exists for the two
# cases where you do:
#
#   - your did:web lives on a hostname you control and you would rather serve a
#     static file than route traffic into the identity-hub;
#   - you want to see what counterparties will fetch, and check it against the
#     DID before anything depends on it.
#
# did:web resolution is a plain HTTPS GET. The DID
#     did:web:connector.example.org:acme:ih:did
# must resolve at
#     https://connector.example.org/acme/ih/did/did.json
# and a DID with no path segments, did:web:example.org, at
#     https://example.org/.well-known/did.json
# This script prints the exact URL for your DID.
#
# Usage: did-document.sh [--output <file>]
#        (default output: compose/secrets/did.json)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) OUT="${2:?--output needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd openssl
load_env

OUT="${OUT:-${SECRETS_DIR}/did.json}"
PUBLIC_PEM="${SECRETS_DIR}/${VAULT_ALIAS_PUBLIC_KEY}.pem"
[ -f "$PUBLIC_PEM" ] || die "no public key at compose/secrets/$(basename "$PUBLIC_PEM") — run gen-keys.sh first"

# ---------------------------------------------------------------------------
# PEM -> JWK
# ---------------------------------------------------------------------------
# An EC public key in SubjectPublicKeyInfo DER ends with the uncompressed point
# 0x04 || X || Y, each coordinate ceil(bits/8) bytes wide. Slicing the DER
# avoids parsing openssl's hex dump and handles P-256, P-384 and P-521 alike.
der="$(mktemp)"; trap 'rm -f "$der"' EXIT
openssl ec -pubin -in "$PUBLIC_PEM" -outform DER -out "$der" 2>/dev/null \
  || die "$(basename "$PUBLIC_PEM") is not an EC public key; this script only handles EC keys"

info_text="$(openssl ec -pubin -in "$PUBLIC_PEM" -text -noout 2>/dev/null)"
bits="$(printf '%s' "$info_text" | sed -n 's/.*Public-Key: (\([0-9]*\) bit).*/\1/p' | head -1)"
[ -n "$bits" ] || die "could not determine the key size of $(basename "$PUBLIC_PEM")"
clen=$(( (bits + 7) / 8 ))

case "$bits" in
  256) crv="P-256" ;;
  384) crv="P-384" ;;
  521) crv="P-521" ;;
  *) die "unsupported curve size ${bits} bits — use prime256v1 (P-256), secp384r1 or secp521r1" ;;
esac

jwk_x="$(tail -c $(( 2 * clen )) "$der" | head -c "$clen" | b64url_nopad_stdin)"
jwk_y="$(tail -c "$clen" "$der" | b64url_nopad_stdin)"

KEY_ID="${PARTICIPANT_DID}#my-key"
CREDENTIAL_SERVICE_URL="${PUBLIC_CREDENTIALS_URL:-http://identity-hub:8282/api/credentials}/v1/participants/${PARTICIPANT_DID_B64}"

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<EOF
{
  "@context": [
    "https://www.w3.org/ns/did/v1",
    "https://w3id.org/security/suites/jws-2020/v1"
  ],
  "id": "${PARTICIPANT_DID}",
  "verificationMethod": [
    {
      "id": "${KEY_ID}",
      "type": "JsonWebKey2020",
      "controller": "${PARTICIPANT_DID}",
      "publicKeyJwk": {
        "kty": "EC",
        "crv": "${crv}",
        "x": "${jwk_x}",
        "y": "${jwk_y}",
        "kid": "${KEY_ID}"
      }
    }
  ],
  "authentication": ["${KEY_ID}"],
  "assertionMethod": ["${KEY_ID}"],
  "service": [
    {
      "id": "dsp-url",
      "type": "DSPMessaging",
      "serviceEndpoint": "${PUBLIC_DSP_URL:-http://control-plane:8282/api/dsp}"
    },
    {
      "id": "credential-service-url",
      "type": "CredentialService",
      "serviceEndpoint": "${CREDENTIAL_SERVICE_URL}"
    }
  ]
}
EOF

ok "wrote ${OUT#"$KIT_ROOT"/}"

# ---------------------------------------------------------------------------
# Where it has to be reachable
# ---------------------------------------------------------------------------
resolve_url="$(did_web_url "$PARTICIPANT_DID")"

printf '\n'
info "this document must be served at:"
printf '    %s\n\n' "$resolve_url"
log  "the identity-hub already serves it there if that URL routes to the"
log  "identity-hub's DID API (container port 8383, base path /api/did)."
log  "Serve this file statically only if you would rather not route to the hub."

# PUBLIC_DID_URL is what you told the kit the DID API is reachable at. If it
# disagrees with what the DID itself resolves to, counterparties will look in
# the wrong place and every credential exchange fails with an unresolvable DID
# — a failure that is hard to read from the logs, so check it here.
if [ -n "${PUBLIC_DID_URL:-}" ]; then
  declared="${PUBLIC_DID_URL%/}/did.json"
  if [ "$declared" != "$resolve_url" ]; then
    printf '\n'
    warn "PUBLIC_DID_URL and PARTICIPANT_DID disagree about where the document lives:"
    warn "  PARTICIPANT_DID resolves to : ${resolve_url}"
    warn "  PUBLIC_DID_URL says         : ${declared}"
    warn "Counterparties follow the DID, so either fix PARTICIPANT_DID or route"
    warn "that URL to the identity-hub's DID API."
  fi
fi
if [ "${DID_WEB_USE_HTTPS:-false}" != "true" ]; then
  printf '\n'
  warn "DID_WEB_USE_HTTPS=false — resolution will use plain http."
  warn "That is fine for a local evaluation and wrong for anything else."
fi
