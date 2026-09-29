#!/usr/bin/env bash
#
# Prove the connector is actually answering.
#
# Everything here is read-only: it creates no assets, no policies, no contracts,
# and writes nothing to Vault or the database. Safe to run against a live
# connector as often as you like.
#
# The checks build on each other, in the order a boot actually happens:
#
#   datastores   Postgres reachable, Vault reachable, key aliases present
#   identity-hub health, DID document served, participant context created,
#                STS client secret minted, an STS token can be issued
#   control-plane health, management API answers (and rejects an unauthenticated
#                caller when authentication is on)
#   data-plane   health, registered with the control-plane
#
# A failing check prints what it means and what to look at. Exit status is 0
# only if every required check passed.
#
# Usage: smoke-test.sh [--wait <seconds>]
#   --wait   keep retrying the health checks for this long before giving up
#            (default 420 — the first boot runs schema migrations and the three
#            runtimes wait for each other at the migration barrier)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

WAIT=420
while [ $# -gt 0 ]; do
  case "$1" in
    --wait) WAIT="${2:?--wait needs a number of seconds}"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd curl
load_env

PASS=0; FAILED=0; SKIPPED=0
pass() { ok "$*"; PASS=$((PASS+1)); }
bad()  { fail "$*"; FAILED=$((FAILED+1)); }
skip() { warn "skipped: $*"; SKIPPED=$((SKIPPED+1)); }

# One deadline for the whole run, not one per service: the three runtimes boot
# in parallel, so waiting $WAIT for each in turn would multiply the timeout by
# three on a stack that is never coming up.
DEADLINE=$(( SECONDS + WAIT ))
remaining() { local r=$(( DEADLINE - SECONDS )); [ "$r" -lt 5 ] && r=5; printf '%s' "$r"; }

H="$CONNECTOR_HOST"
CP_HEALTH="http://${H}:${CP_DEFAULT_HOST_PORT}/api/check/readiness"
CP_MGMT="http://${H}:${CP_MANAGEMENT_HOST_PORT}/api/management"
DP_HEALTH="http://${H}:${DP_DEFAULT_HOST_PORT}/api/check/readiness"
IH_HEALTH="http://${H}:${IH_DEFAULT_HOST_PORT}/api/check/readiness"
IH_IDENTITY="http://${H}:${IH_IDENTITY_HOST_PORT}/api/identity"
IH_DID="http://${H}:${IH_DID_HOST_PORT}/api/did"
IH_STS="http://${H}:${IH_STS_HOST_PORT}/api/sts"

# curl already prints 000 when it never got a response, so the failure branch
# must not print its own or the two are concatenated.
status_of() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$@" 2>/dev/null)" || true
  printf '%s' "${code:-000}"
}

# ===========================================================================
info "datastores"
# ===========================================================================
if vault_up; then
  pass "Vault answers at ${VAULT_ADDR_HOST}"
else
  bad "Vault is not answering at ${VAULT_ADDR_HOST}
     nothing else can work without it — docker compose logs vault"
fi

if pg_up; then
  pass "PostgreSQL '${POSTGRES_DB}' reachable as '${POSTGRES_USER}'"
else
  bad "cannot reach PostgreSQL '${POSTGRES_DB}' — docker compose logs postgres"
fi

for alias_name in "$VAULT_ALIAS_PUBLIC_KEY" "$VAULT_ALIAS_PRIVATE_KEY"; do
  if vault_has "$alias_name"; then
    pass "Vault holds '${alias_name}'"
  else
    bad "Vault has no '${alias_name}'
     the identity-hub will not start without the public key — run scripts/bootstrap.sh"
  fi
done

# ===========================================================================
info "identity-hub"
# ===========================================================================
log "waiting up to ${WAIT}s for the runtimes to report ready"
if wait_for_http "$IH_HEALTH" "$(remaining)" "identity-hub readiness"; then
  pass "identity-hub is ready (${IH_HEALTH})"
else
  bad "identity-hub never became ready
     docker compose logs identity-hub
     a missing public key alias in Vault is the usual cause"
fi

did_doc="$(curl -sS --max-time 15 "${IH_DID}/did.json" 2>/dev/null || true)"
if printf '%s' "$did_doc" | grep -q "\"$PARTICIPANT_DID\""; then
  pass "DID document served at ${IH_DID}/did.json and carries the right id"
else
  bad "the DID document at ${IH_DID}/did.json does not name ${PARTICIPANT_DID}
     got: $(printf '%s' "$did_doc" | head -c 200)"
fi

if printf '%s' "$did_doc" | grep -q '"DSPMessaging"' && printf '%s' "$did_doc" | grep -q '"CredentialService"'; then
  pass "DID document advertises both DSPMessaging and CredentialService endpoints"
else
  bad "the DID document is missing a service entry — check EDC_IH_API_SUPERUSER_SERVICES.
     Note it is only applied when the participant context is CREATED; changing it
     later has no effect until the context is recreated."
fi

code="$(status_of "${IH_IDENTITY}/v1alpha/participants/${PARTICIPANT_DID_B64}/credentials")"
if [ "$code" = "200" ]; then
  pass "participant context exists (Identity API answered 200)"
else
  bad "the Identity API returned ${code} for this participant's credentials.
     If it is 404 the participant context was never created: check the
     identity-hub log for the participant-context seeding step."
fi

if vault_has "$STS_CLIENT_SECRET_ALIAS"; then
  pass "STS client secret minted at '${STS_CLIENT_SECRET_ALIAS}'"
else
  bad "no STS client secret at '${STS_CLIENT_SECRET_ALIAS}'.
     The identity-hub mints it only when it CREATES the participant context.
     If the context already exists but the secret is gone — which is what
     happens when the bundled dev-mode Vault restarts — set
     IH_SUPERUSER_FORCE_RECREATE=true in .env for one boot to re-mint it."
fi

# ===========================================================================
info "control-plane"
# ===========================================================================
if wait_for_http "$CP_HEALTH" "$(remaining)" "control-plane readiness"; then
  pass "control-plane is ready (${CP_HEALTH})"
else
  bad "control-plane never became ready
     docker compose logs control-plane
     a missing DSE_AUTHORITY_DID or a malformed trusted-issuer entry both fail the boot"
fi

MGMT_KEY=""
if [ "$MANAGEMENT_API_AUTH_ENABLED" = "true" ]; then
  MGMT_KEY="$(vault_get "$MANAGEMENT_API_KEY_ALIAS" 2>/dev/null || true)"
  if [ -z "$MGMT_KEY" ] && [ -f "${SECRETS_DIR}/management-api-key.txt" ]; then
    MGMT_KEY="$(tr -d '\n' < "${SECRETS_DIR}/management-api-key.txt")"
  fi
  [ -n "$MGMT_KEY" ] || warn "could not read the management API key from Vault or compose/secrets/"
fi

# The API key travels in a 0600 curl config file, not in argv — see
# secret_curl in lib/common.sh. The request body has no secret in it, but it
# goes the same way for symmetry with the calls below.
mgmt_query() {
  local key="$1" code
  code="$( { [ -n "$key" ] && printf 'header = "x-api-key: %s"\n' "$key"; } \
    | secret_curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
        --request POST \
        --header 'Content-Type: application/json' \
        --data '{"@context":{"@vocab":"https://w3id.org/edc/v0.0.1/ns/"},"offset":0,"limit":1}' \
        "${CP_MGMT}/v3/assets/request" 2>/dev/null )" || true
  printf '%s' "${code:-000}"
}

code="$(mgmt_query "$MGMT_KEY")"
if [ "$code" = "200" ]; then
  pass "management API answers (POST ${CP_MGMT}/v3/assets/request -> 200)"
else
  bad "the management API returned ${code} instead of 200.
     401/403 means the API key is wrong; 000 means nothing is listening."
fi

if [ "$MANAGEMENT_API_AUTH_ENABLED" = "true" ]; then
  code="$(mgmt_query "")"
  case "$code" in
    401|403) pass "management API rejects an unauthenticated caller (${code})" ;;
    200)     bad "the management API accepted a request WITH NO API KEY.
     Authentication is not in effect even though MANAGEMENT_API_AUTH_ENABLED=true.
     Check web.http.management.auth.* in config/control-plane/config.properties
     and re-run scripts/render-config.sh, then restart the control-plane." ;;
    *)       skip "unauthenticated management call returned ${code}, cannot judge" ;;
  esac
else
  skip "management API authentication is disabled in .env — anyone who reaches port ${CP_MANAGEMENT_HOST_PORT} has full control"
fi

# ===========================================================================
info "data-plane"
# ===========================================================================
if wait_for_http "$DP_HEALTH" "$(remaining)" "data-plane readiness"; then
  pass "data-plane is ready (${DP_HEALTH})"
else
  bad "data-plane never became ready
     docker compose logs data-plane
     it registers against the control-plane at boot and exits if that fails;
     one restart on a first boot is expected, a restart loop is not"
fi

if [ -n "${MGMT_KEY}" ] || [ "$MANAGEMENT_API_AUTH_ENABLED" != "true" ]; then
  dp_list="$( { [ -n "${MGMT_KEY}" ] && printf 'header = "x-api-key: %s"\n' "${MGMT_KEY}"; } \
    | secret_curl -sS --max-time 20 "${CP_MGMT}/v3/dataplanes" 2>/dev/null || true)"
  if printf '%s' "$dp_list" | grep -q 'http://data-plane:8383'; then
    pass "data-plane is registered with the control-plane"
  elif printf '%s' "$dp_list" | grep -qE '^\[[[:space:]]*\]$'; then
    bad "the control-plane knows of no data-plane.
     Check EDC_DPF_SELECTOR_URL and the data-plane log for its registration call."
  else
    skip "could not read the data-plane registry (this endpoint varies by EDC version)"
  fi
else
  skip "data-plane registration check needs the management API key"
fi

# ===========================================================================
info "end-to-end: can the control-plane get a token from its own STS?"
# ===========================================================================
# This is the single most informative check. It exercises the whole identity
# chain: the client secret the identity-hub minted, the private key in Vault,
# and the STS endpoint the control-plane authenticates against.
sts_secret="$(vault_get "$STS_CLIENT_SECRET_ALIAS" 2>/dev/null || true)"
if [ -z "$sts_secret" ]; then
  skip "no STS client secret to test with"
else
  # client_secret is a live credential: it goes in through the curl config
  # file, not as a --data-urlencode argument visible in the process table.
  sts_body="$( {
      printf 'data-urlencode = "grant_type=client_credentials"\n'
      printf 'data-urlencode = "client_id=%s"\n'     "${PARTICIPANT_DID}"
      printf 'data-urlencode = "client_secret=%s"\n' "${sts_secret}"
      printf 'data-urlencode = "audience=%s"\n'      "${PARTICIPANT_DID}"
    } | secret_curl -sS --max-time 20 \
      --request POST \
      --header 'Content-Type: application/x-www-form-urlencoded' \
      "${IH_STS}/token" 2>/dev/null || true)"
  if printf '%s' "$sts_body" | grep -q '"access_token"'; then
    pass "STS issued a token — identity, key material and client secret all line up"
  else
    bad "the STS did not issue a token.
     response: $(printf '%s' "$sts_body" | head -c 300)
     A missing private key in Vault under '${VAULT_ALIAS_PRIVATE_KEY}' is the usual cause."
  fi
fi

# ===========================================================================
printf '\n'
info "result: ${PASS} passed, ${FAILED} failed, ${SKIPPED} skipped"
if [ "$FAILED" -eq 0 ]; then
  ok "the connector is answering"
  printf '\n'
  log "What this does NOT prove: that you are a member of a dataspace. That"
  log "needs a MembershipCredential issued by the authority to ${PARTICIPANT_DID},"
  log "a DID that resolves from the authority's network, and AUTHORITY_DID +"
  log "TRUSTED_ISSUERS pointing at the real authority."
  exit 0
fi
fail "the connector is not fully up"
exit 1
