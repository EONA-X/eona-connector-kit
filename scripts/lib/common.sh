#!/usr/bin/env bash
# Shared helpers for the EONA-X connector kit scripts.
# Sourced, never executed directly.

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
# Resolved from this file's own location so the scripts work from any cwd.
_common_sh_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd -- "${_common_sh_dir}/.." && pwd)"
KIT_ROOT="$(cd -- "${SCRIPTS_DIR}/.." && pwd)"
COMPOSE_DIR="${KIT_ROOT}/compose"
# shellcheck disable=SC2034  # used by the scripts that source this file
CONFIG_DIR="${COMPOSE_DIR}/config"
# shellcheck disable=SC2034  # used by the scripts that source this file
SECRETS_DIR="${COMPOSE_DIR}/secrets"
ENV_FILE="${ENV_FILE:-${COMPOSE_DIR}/.env}"
ENV_EXAMPLE="${COMPOSE_DIR}/.env.example"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _c_reset=$'\033[0m'; _c_red=$'\033[31m'; _c_grn=$'\033[32m'
  _c_ylw=$'\033[33m'; _c_dim=$'\033[2m'; _c_bold=$'\033[1m'
else
  _c_reset=''; _c_red=''; _c_grn=''; _c_ylw=''; _c_dim=''; _c_bold=''
fi

log()   { printf '%s\n' "${_c_dim}·${_c_reset} $*"; }
info()  { printf '%s\n' "${_c_bold}==>${_c_reset} $*"; }
ok()    { printf '%s\n' "${_c_grn}ok${_c_reset}   $*"; }
warn()  { printf '%s\n' "${_c_ylw}warn${_c_reset} $*" >&2; }
fail()  { printf '%s\n' "${_c_red}fail${_c_reset} $*" >&2; }
die()   { fail "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
require_cmd() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { fail "required command not found: $c"; missing=1; }
  done
  [ "$missing" -eq 0 ] || die "install the missing commands and try again"
}

compose() {
  # Docker Compose v2 only. The v1 "docker-compose" binary is not supported.
  # EXTERNAL_DATASTORES=1 layers the bring-your-own-Postgres/Vault override on
  # top, exactly as the documented command line does. A compose.local.yaml,
  # if you have one, is layered last (git-ignored: extra_hosts, resource
  # limits, anything specific to your host).
  local files=(-f compose.yaml)
  [ "${EXTERNAL_DATASTORES:-0}" = "1" ] && files+=(-f compose.external-datastores.yaml)
  [ -f "${COMPOSE_DIR}/compose.local.yaml" ] && files+=(-f compose.local.yaml)
  ( cd "$COMPOSE_DIR" && docker compose "${files[@]}" --env-file "$ENV_FILE" "$@" )
}

# Resolved image reference of one service. `compose config --images <svc>`
# prints every image in the project rather than that service's, so read the
# rendered configuration instead.
service_image() {
  compose config 2>/dev/null | awk -v svc="$1" '
    /^services:/       { in_services = 1; next }
    !in_services       { next }
    /^  [^ ][^:]*:$/   { current = $1; sub(":$", "", current); next }
    current == svc && $1 == "image:" { print $2; exit }
  '
}

# Resolved value of one environment variable of one service, read from the
# rendered configuration for the same reason as service_image. Prints nothing if
# the service or the variable is not there.
service_env() {
  compose config 2>/dev/null | awk -v svc="$1" -v key="$2" '
    /^services:/       { in_services = 1; next }
    !in_services       { next }
    /^  [^ ][^:]*:$/   { current = $1; sub(":$", "", current); next }
    current == svc && $1 == key ":" { print $2; exit }
  '
}

# Report on the three connector images. Docker's own error for a missing image
# is whatever the registry host happens to answer, which for the "localhost"
# default is meaningless, so say it plainly instead.
#   check_connector_images fatal   -> exit if they cannot possibly be pulled
#   check_connector_images warn    -> report and carry on
check_connector_images() {
  local mode="${1:-warn}" svc image missing="" unresolved=""
  for svc in control-plane data-plane identity-hub; do
    image="$(service_image "$svc")"
    if [ -z "$image" ]; then
      unresolved="${unresolved} ${svc}"
      continue
    fi
    if docker image inspect "$image" >/dev/null 2>&1; then
      log "present: $image"
    else
      missing="${missing} ${image}"
    fi
  done

  # An image we could not even resolve must never be reported as available.
  if [ -n "${unresolved// /}" ]; then
    local umsg="could not resolve the image of:${unresolved}
  'docker compose config' failed or printed no image. Run it from compose/
  with --env-file ${ENV_FILE} to see why."
    if [ "$mode" = "fatal" ]; then die "$umsg"; else warn "$umsg"; fi
    return 1
  fi

  if [ -z "${missing// /}" ]; then
    ok "all three connector images are available locally"
    return 0
  fi

  # A "localhost" registry with nothing built is unrecoverable: there is no
  # registry there to pull from. Anything else might just need a pull.
  if [ "${EDC_IMAGE_REGISTRY:-ghcr.io}" = "localhost" ] \
     && [ -z "${CONTROL_PLANE_IMAGE:-}${DATA_PLANE_IMAGE:-}${IDENTITY_HUB_IMAGE:-}" ]; then
    local msg
    # shellcheck disable=SC2086  # $missing is a space-separated list on purpose
    msg="these images are not on this machine and cannot be pulled from 'localhost':
$(printf '      %s\n' $missing)
  Build them from the connector source:
      cd <dataspace-ecosystem checkout> && ./gradlew dockerize
  which produces exactly localhost/local/<launcher>:latest. Or unset
  EDC_IMAGE_REGISTRY / EDC_IMAGE_NAMESPACE to fall back to the published
  images. To build straight into your own registry instead:
      ./gradlew dockerize -PregistryHost=<host> -PregistryNs=<ns> -PimageTags=<tag>
  and set EDC_IMAGE_REGISTRY / EDC_IMAGE_NAMESPACE / EDC_IMAGE_TAG in
  ${ENV_FILE} to match."
    if [ "$mode" = "fatal" ]; then die "$msg"; else warn "$msg"; fi
    return 1
  fi

  warn "not on this machine yet; compose will try to pull:"
  # shellcheck disable=SC2086
  printf '       %s\n' $missing
  warn "if your registry needs credentials, run 'docker login <registry>' first"
  return 0
}

# ---------------------------------------------------------------------------
# Environment file
# ---------------------------------------------------------------------------
# The .env is read two ways: by Docker Compose, and by these scripts sourcing
# it. Keep it to plain KEY=value lines so both agree — no command substitution,
# no multi-line values.
load_env() {
  [ -f "$ENV_FILE" ] || die "no env file at $ENV_FILE — copy $ENV_EXAMPLE to .env and edit it"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a

  : "${PARTICIPANT_ID:?PARTICIPANT_ID is not set in $ENV_FILE}"
  : "${PARTICIPANT_DID:?PARTICIPANT_DID is not set in $ENV_FILE}"
  : "${AUTHORITY_DID:?AUTHORITY_DID is not set in $ENV_FILE}"
  : "${VAULT_TOKEN:?VAULT_TOKEN is not set in $ENV_FILE}"
  : "${POSTGRES_USER:?POSTGRES_USER is not set in $ENV_FILE}"
  : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set in $ENV_FILE}"

  # Defaults mirroring compose.yaml, so a script never disagrees with the stack.
  : "${POSTGRES_HOST:=postgres}"
  : "${POSTGRES_PORT:=5432}"
  : "${POSTGRES_DB:=edc}"
  : "${POSTGRES_JDBC_PARAMS:=}"
  : "${POSTGRES_HOST_PORT:=15432}"
  : "${VAULT_URL:=http://vault:8200}"
  : "${VAULT_HOST_PORT:=18200}"
  : "${VAULT_SECRET_PATH:=/v1/secret}"
  : "${VAULT_FOLDER:=}"
  : "${VAULT_ALIAS_PRIVATE_KEY:=participant-signing-key}"
  : "${VAULT_ALIAS_PUBLIC_KEY:=participant-signing-key-pub}"
  : "${STS_CLIENT_SECRET_ALIAS:=${PARTICIPANT_DID}-sts-client-secret}"
  : "${MANAGEMENT_API_AUTH_ENABLED:=true}"
  : "${MANAGEMENT_API_KEY_ALIAS:=management-api-key}"
  : "${BIND_ADDRESS:=127.0.0.1}"
  : "${CP_MANAGEMENT_HOST_PORT:=18181}"
  : "${CP_DEFAULT_HOST_PORT:=18080}"
  : "${CP_PROTOCOL_HOST_PORT:=18282}"
  : "${DP_DEFAULT_HOST_PORT:=28080}"
  : "${DP_PUBLIC_HOST_PORT:=28181}"
  : "${DP_DATA_HOST_PORT:=28282}"
  : "${IH_DEFAULT_HOST_PORT:=38080}"
  : "${IH_IDENTITY_HOST_PORT:=38181}"
  : "${IH_CREDENTIALS_HOST_PORT:=38282}"
  : "${IH_DID_HOST_PORT:=38383}"
  : "${IH_STS_HOST_PORT:=38484}"
  : "${KEY_CURVE:=prime256v1}"

  # Host-side addresses. The connectors reach Vault and Postgres over the
  # compose network; these scripts run on the host and reach them over the
  # published ports — unless the datastore is external, in which case its own
  # address is already the right one. Both are overridable in .env.
  local bind_host="$BIND_ADDRESS"
  [ "$bind_host" = "0.0.0.0" ] && bind_host="127.0.0.1"
  : "${CONNECTOR_HOST:=${bind_host}}"

  if [ "$POSTGRES_HOST" = "postgres" ]; then
    POSTGRES_BUNDLED=1
    : "${POSTGRES_HOST_ADDR:=${bind_host}}"
    : "${POSTGRES_PORT_ADDR:=${POSTGRES_HOST_PORT}}"
  else
    POSTGRES_BUNDLED=0
    : "${POSTGRES_HOST_ADDR:=${POSTGRES_HOST}}"
    : "${POSTGRES_PORT_ADDR:=${POSTGRES_PORT}}"
  fi

  case "$VAULT_URL" in
    http://vault:*|https://vault:*)
      : "${VAULT_ADDR_HOST:=http://${bind_host}:${VAULT_HOST_PORT}}" ;;
    *)
      : "${VAULT_ADDR_HOST:=${VAULT_URL}}" ;;
  esac

  VAULT_ADDR_HOST="${VAULT_ADDR_HOST%/}"
}

# ---------------------------------------------------------------------------
# did:web
# ---------------------------------------------------------------------------
# The URL a did:web resolves to. did:web:<host, %3A for a port>[:<path>...]
# becomes https://<host>/<path>/did.json, or https://<host>/.well-known/did.json
# when there is no path. http instead of https while DID_WEB_USE_HTTPS is not
# true, matching what the runtimes themselves do.
did_web_url() {
  local did="$1" body host path scheme="https"
  [ "${DID_WEB_USE_HTTPS:-false}" = "true" ] || scheme="http"
  body="${did#did:web:}"
  host="${body%%:*}"
  path="${body#*:}"
  host="${host//%3A/:}"
  host="${host//%3a/:}"
  if [ "$path" = "$body" ]; then
    printf '%s://%s/.well-known/did.json' "$scheme" "$host"
  else
    printf '%s://%s/%s/did.json' "$scheme" "$host" "${path//:/\/}"
  fi
}

# ---------------------------------------------------------------------------
# PostgreSQL, from the host
# ---------------------------------------------------------------------------
# Three ways to get a psql, in order of least setup required: the bundled
# container, a psql on the host, a throwaway container on the compose network.
#
# PGPASSWORD is exported into this function's own environment and the bare
# `-e PGPASSWORD` form (no "=value") is handed to docker, which forwards the
# value from the caller's environment WITHOUT putting it in argv. Writing
# `-e PGPASSWORD="$POSTGRES_PASSWORD"` would publish the database password to
# every local user through /proc/<pid>/cmdline for the life of the call.
pg_psql() {
  local db="$1"; shift
  local -x PGPASSWORD="$POSTGRES_PASSWORD"
  if [ "${POSTGRES_BUNDLED:-0}" = "1" ]; then
    compose exec -T -e PGPASSWORD postgres \
      psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d "$db" "$@"
  elif command -v psql >/dev/null 2>&1; then
    psql -v ON_ERROR_STOP=1 \
      -h "$POSTGRES_HOST_ADDR" -p "$POSTGRES_PORT_ADDR" -U "$POSTGRES_USER" -d "$db" "$@"
  else
    docker run --rm -i \
      --network "${COMPOSE_PROJECT_NAME:-eonax-connector}_default" \
      -e PGPASSWORD \
      "${POSTGRES_IMAGE:-postgres:16-alpine}" \
      psql -v ON_ERROR_STOP=1 \
        -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$db" "$@"
  fi
}

pg_up() {
  pg_psql "${1:-$POSTGRES_DB}" -tAc 'SELECT 1' >/dev/null 2>&1
}

pg_wait() {
  local deadline=$(( SECONDS + ${1:-90} ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    pg_up "${2:-$POSTGRES_DB}" && return 0
    sleep 2
  done
  return 1
}

# ---------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------
# base64url, no padding — the form EDC uses for participant ids in URLs.
b64url_nopad() {
  printf '%s' "$1" | base64 | tr -d '\n' | tr -d '=' | tr '+/' '-_'
}

# base64url of raw bytes on stdin, no padding (for JWK coordinates).
b64url_nopad_stdin() {
  base64 | tr -d '\n' | tr -d '=' | tr '+/' '-_'
}

# Minimal JSON string escaping: backslash, quote, and the control characters
# that actually occur in PEM payloads (newline, carriage return, tab).
json_escape() {
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' \
    | awk 'BEGIN{ORS=""} {print sep $0; sep="\\n"}'
}

# ---------------------------------------------------------------------------
# Vault (KV v2, over the HTTP API — no vault CLI needed)
# ---------------------------------------------------------------------------
# Effective path is <VAULT_ADDR_HOST><VAULT_SECRET_PATH>/data/[<folder>/]<alias>
# and EDC reads the value out of the "content" field. Keep VAULT_SECRET_PATH and
# VAULT_FOLDER in step with what the runtimes are configured with, or aliases
# will not resolve.
#
# THE ALIAS MUST BE ENCODED EXACTLY THE WAY EDC ENCODES IT, or these scripts
# address a different Vault entry than the connector does. EDC's
# HashicorpVaultClient.getSecretUrl does:
#
#     key = URLEncoder.encode(alias, UTF_8).replace("%2F", "/")
#     url = <vault>/<secretPath>/data[/<folder>]/ + addPathSegments(key)
#
# and okhttp's addPathSegments treats its argument as NOT already encoded, so
# it percent-encodes the '%' characters URLEncoder just produced. Vault then
# decodes the wire path once, which means the entry EDC actually creates is
# named URLEncoder.encode(alias) — with literal "%3A" text where the alias had
# a colon. Verified against Vault 1.20.4: an alias of
#     did:web:identity-hub%3A8383:api:did-sts-client-secret
# lands at the key
#     did%3Aweb%3Aidentity-hub%253A8383%3Aapi%3Adid-sts-client-secret
# while the naive raw path lands at
#     did:web:identity-hub:8383:api:did-sts-client-secret
# — two distinct, coexisting entries. This bites EVERY DID-derived alias, not
# only ones containing a '%': any colon is enough. It is why the STS client
# secret the identity-hub mints could not be found.
#
# Plain aliases ([A-Za-z0-9.*_-] only, which is what the kit's own defaults
# are) encode to themselves, so nothing moves for them.

# java.net.URLEncoder.encode(s, UTF_8), then "%2F" -> "/". This is the Vault
# KEY name. Byte-oriented (LC_ALL=C) so multi-byte UTF-8 encodes per byte, the
# way URLEncoder does.
vault_alias_key() {
  local s="$1" out='' i n c
  local LC_ALL=C
  n=${#s}
  for (( i = 0; i < n; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.*_-]) out="${out}${c}" ;;
      ' ')             out="${out}+" ;;
      *)               out="${out}$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "${out//%2F//}"
}

# The wire form of that key: okhttp re-encodes '%' when adding the path
# segment, and Vault's single decode then yields the key above.
vault_alias_wire() {
  local key
  key="$(vault_alias_key "$1")"
  printf '%s' "${key//%/%25}"
}

# $2 = "raw" to build the legacy un-encoded path instead (used only as a
# read-side fallback, in case a runtime wrote an alias without encoding it).
vault_path() {
  local alias="$1"
  local mode="${2:-edc}"
  local folder="${VAULT_FOLDER:-}"
  local seg
  if [ "$mode" = "raw" ]; then
    seg="$alias"
  else
    seg="$(vault_alias_wire "$alias")"
  fi
  if [ -n "$folder" ]; then
    printf '%s%s/data/%s/%s' "$VAULT_ADDR_HOST" "$VAULT_SECRET_PATH" "$folder" "$seg"
  else
    printf '%s%s/data/%s' "$VAULT_ADDR_HOST" "$VAULT_SECRET_PATH" "$seg"
  fi
}

# curl with secrets kept OFF the command line.
#
# Anything passed to curl as an argument is world-readable in /proc/<pid>/cmdline
# and in `ps -eo args` for as long as the process lives, so on a shared host any
# unprivileged local user could read the Vault token, the participant private
# key, the management API key and the STS client secret straight out of the
# process table while these scripts ran. curl's --config file is read from a
# 0600 temp file instead, and request bodies go in on stdin via --data @-.
#
#   secret_curl <config-lines-on-stdin?> ...
# Usage:
#   printf 'header = "X-Vault-Token: %s"\n' "$TOK" | secret_curl -fsS "$url"
# Anything piped in becomes the curl config; pass the body with body_curl.
secret_curl() {
  local cfg rc
  cfg="$(mktemp)" || return 1
  chmod 0600 "$cfg"
  cat > "$cfg"
  curl --config "$cfg" "$@"
  rc=$?
  rm -f "$cfg"
  return "$rc"
}

# As secret_curl, but the FIRST argument is a request body fed to curl on
# stdin (--data @-) so it never appears in argv either.
body_curl() {
  local body="$1"; shift
  local cfg rc
  cfg="$(mktemp)" || return 1
  chmod 0600 "$cfg"
  cat > "$cfg"
  printf '%s' "$body" | curl --config "$cfg" --data @- "$@"
  rc=$?
  rm -f "$cfg"
  return "$rc"
}

# The Vault token as a curl config line. Never interpolated into argv.
_vault_token_cfg() {
  printf 'header = "X-Vault-Token: %s"\n' "${VAULT_TOKEN}"
}

vault_up() {
  curl -fsS --max-time 5 "${VAULT_ADDR_HOST}/v1/sys/health?standbyok=true" >/dev/null 2>&1
}

vault_wait() {
  local deadline=$(( SECONDS + ${1:-60} ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    vault_up && return 0
    sleep 2
  done
  return 1
}

# Prints the secret's "content" field, or nothing if the alias does not exist.
# Unescapes the three JSON escapes that occur in what this kit stores (newline,
# quote, backslash) so a PEM comes back byte-identical; it is not a general
# JSON string decoder and does not handle \uXXXX.
# Raw JSON of one secret, or non-zero if the alias does not exist. Tries the
# EDC-encoded path first, then the legacy un-encoded one, so an entry written
# before this encoding was fixed is still found.
vault_fetch() {
  local alias="$1" body
  if body="$(_vault_token_cfg | secret_curl -fsS --max-time 10 "$(vault_path "$alias")" 2>/dev/null)"; then
    printf '%s' "$body"; return 0
  fi
  local raw
  raw="$(vault_path "$alias" raw)"
  [ "$raw" != "$(vault_path "$alias")" ] || return 1
  if body="$(_vault_token_cfg | secret_curl -fsS --max-time 10 "$raw" 2>/dev/null)"; then
    printf '%s' "$body"; return 0
  fi
  return 1
}

vault_get() {
  local body
  body="$(vault_fetch "$1")" || return 1
  printf '%s' "$body" \
    | sed -n 's/.*"content"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p' \
    | awk '{ gsub(/\\n/, "\n"); gsub(/\\"/, "\""); gsub(/\\\\/, "\\"); print }'
}

vault_has() {
  vault_fetch "$1" >/dev/null 2>&1
}

# Always writes to the EDC-encoded path: that is where the runtimes look.
vault_put() {
  local alias="$1" value="$2" payload
  payload="{\"data\":{\"content\":\"$(json_escape "$value")\"}}"
  _vault_token_cfg \
    | body_curl "$payload" -fsS -o /dev/null --max-time 15 \
        --request POST \
        --header 'Content-Type: application/json' \
        "$(vault_path "$alias")"
}

# Write only when absent (idempotent re-runs never rotate a live key).
vault_put_if_absent() {
  local alias="$1" value="$2"
  if vault_has "$alias"; then
    log "vault: $alias already present, leaving it alone"
    return 0
  fi
  vault_put "$alias" "$value" || die "vault: could not write $alias"
  ok "vault: wrote $alias"
}

# ---------------------------------------------------------------------------
# HTTP polling
# ---------------------------------------------------------------------------
http_ok() {
  curl -fsS -o /dev/null --max-time "${2:-5}" "$1" 2>/dev/null
}

wait_for_http() {
  local url="$1" timeout="${2:-300}" label="${3:-$1}"
  local deadline=$(( SECONDS + timeout ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    http_ok "$url" && return 0
    sleep 3
  done
  fail "timed out after ${timeout}s waiting for ${label}"
  return 1
}
