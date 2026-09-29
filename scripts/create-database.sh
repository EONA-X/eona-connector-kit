#!/usr/bin/env bash
#
# Make sure the connector has a database it can migrate into.
#
# There is no schema to install. EDC_SQL_SCHEMA_AUTOCREATE is false and Flyway
# owns every table, applying its migrations in-process at boot. So all this
# script does is prove three things and fix the first when it can:
#
#   1. the database exists
#   2. the connector's role can connect to it
#   3. that role has schema-owner DDL rights — Flyway CREATEs, DROPs and ALTERs,
#      so a read-write-only grant will not boot
#
# With the bundled PostgreSQL the database is created by the image's own initdb
# from POSTGRES_DB/POSTGRES_USER/POSTGRES_PASSWORD, so this is a check. Against
# an external instance it will try to create the database if the role is allowed
# to, and tell you exactly what to ask your DBA for if it is not.
#
# Idempotent.
#
# Usage: create-database.sh
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd docker
load_env

info "checking PostgreSQL at ${POSTGRES_HOST_ADDR}:${POSTGRES_PORT_ADDR}, database '${POSTGRES_DB}'"

if pg_wait 90; then
  ok "connected to '${POSTGRES_DB}' as '${POSTGRES_USER}'"
else
  # Could not reach the target database. Try the maintenance database, which is
  # where a CREATE DATABASE has to be issued from anyway.
  if pg_up postgres; then
    warn "database '${POSTGRES_DB}' is not reachable; attempting to create it"
    if pg_psql postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '${POSTGRES_DB}'" | grep -q 1; then
      die "database '${POSTGRES_DB}' exists but role '${POSTGRES_USER}' cannot connect to it.
  Grant it:  GRANT CONNECT ON DATABASE \"${POSTGRES_DB}\" TO \"${POSTGRES_USER}\";"
    fi
    pg_psql postgres -c "CREATE DATABASE \"${POSTGRES_DB}\" OWNER \"${POSTGRES_USER}\"" \
      || die "could not create database '${POSTGRES_DB}'.
  Ask for it to be created for you:
    CREATE DATABASE \"${POSTGRES_DB}\" OWNER \"${POSTGRES_USER}\";"
    ok "created database '${POSTGRES_DB}'"
    pg_wait 30 || die "still cannot connect to '${POSTGRES_DB}' after creating it"
  else
    die "cannot reach PostgreSQL at ${POSTGRES_HOST_ADDR}:${POSTGRES_PORT_ADDR}
  bundled: start it with   docker compose up -d postgres
  external: check POSTGRES_HOST / POSTGRES_PORT / credentials in $ENV_FILE"
  fi
fi

# ---------------------------------------------------------------------------
# DDL rights. Done inside a transaction that is always rolled back, so this
# leaves nothing behind even on a database that already holds real data.
# ---------------------------------------------------------------------------
info "checking that '${POSTGRES_USER}' can run the DDL Flyway needs"
if pg_psql "$POSTGRES_DB" -q <<'SQL' >/dev/null 2>&1
BEGIN;
CREATE TABLE dse_kit_ddl_probe (id varchar PRIMARY KEY, n integer);
CREATE INDEX dse_kit_ddl_probe_idx ON dse_kit_ddl_probe (n);
ALTER TABLE dse_kit_ddl_probe ALTER COLUMN n SET NOT NULL;
DROP INDEX dse_kit_ddl_probe_idx;
DROP TABLE dse_kit_ddl_probe;
ROLLBACK;
SQL
then
  ok "DDL rights confirmed"
else
  die "role '${POSTGRES_USER}' cannot create/alter/drop tables in '${POSTGRES_DB}'.
  Flyway needs schema-owner rights. Grant them:
    ALTER DATABASE \"${POSTGRES_DB}\" OWNER TO \"${POSTGRES_USER}\";
  or, for a dedicated schema:
    GRANT ALL ON SCHEMA public TO \"${POSTGRES_USER}\";"
fi

# ---------------------------------------------------------------------------
# Report what is already there, so a re-run tells you where you are.
# ---------------------------------------------------------------------------
tables="$(pg_psql "$POSTGRES_DB" -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema = current_schema()" 2>/dev/null | tr -d '[:space:]')"
if [ "${tables:-0}" = "0" ]; then
  log "the schema is empty — Flyway will build it on first boot"
else
  log "${tables} table(s) already present; Flyway will migrate rather than baseline"
  barrier="$(pg_psql "$POSTGRES_DB" -tAc \
    "SELECT string_agg(module_name, ', ' ORDER BY module_name) FROM dse_migration_barrier" 2>/dev/null | tr -d '\r')"
  [ -n "${barrier// /}" ] && log "migration barrier already signalled by: ${barrier}"
fi

ok "database ready"
