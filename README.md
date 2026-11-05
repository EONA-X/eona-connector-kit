# EONA-X participant connector kit

Run your own EONA-X dataspace participant connector, on your own infrastructure.

This kit packages the four services that make up a participant connector — an
Eclipse Dataspace Components (EDC) **control-plane**, **data-plane** and
**identity-hub**, plus the **HashiCorp Vault** they all depend on, backed by
**PostgreSQL** — as a self-contained [Docker Compose](compose/) deployment:
evaluation, development, or a single-host deployment behind your own proxy.

It is *not* a fork of the connector. It deploys the connector images that EONA-X
builds from the `dataspace-ecosystem` source tree (EDC 0.15.0).

---

## Read this before you start

**You cannot complete this on your own today.** Two things must come from
EONA-X, and one of them is a hard blocker:

1. **Membership in the dataspace.** The authority must declare you as a holder
   and deliver an attestation before your identity-hub can obtain a
   `MembershipCredential`. You cannot self-serve this.
2. **The authority's DID** (and the DIDs of any peers you will verify), for the
   trusted-issuer list and for `DSE_AUTHORITY_DID`. The control-plane will not
   boot without the latter.

Everything else — your DID, your hostnames, your database, your Vault, your key
material — is yours to decide and operate.

[`docs/prerequisites.md`](docs/prerequisites.md) lists exactly what to ask for
and what blocks what. Read it first.

### What has actually been tested

Honest state of this kit, so you know where you are the first one walking:

- The compose file passes `docker compose config` with and without the
  external-datastore override.
- The bootstrap path has been run end to end for real: datastores started, key
  pair generated, Vault seeded, database DDL rights probed, configuration
  rendered, DID document produced — and re-run to prove idempotency.
- **No EDC runtime has been started against this configuration**, because the
  images were not available on the machine where the kit was written. The
  configuration is derived from the running EONA-X deployment and verified
  against the EDC 0.15.0 artifacts and the connector source, but the first
  person to run it with real images is doing the first real boot. Expect to
  find something. The troubleshooting section below is written for that.

---

## What gets deployed

```
                        ┌──────────────────────────────────────────┐
   other connectors ───▶│ control-plane  :8282 /api/dsp            │  PUBLIC
                        │                :8181 /api/management     │  internal
                        │                :8383 /api/control        │  internal
                        │                :8080 /api/check/*        │  probes
                        └───────┬───────────────────────┬──────────┘
                                │ signals data flows    │ STS token
                                ▼                       ▼
                        ┌───────────────────┐   ┌───────────────────────────┐
   consumers ──────────▶│ data-plane        │   │ identity-hub              │
                  :8181 │ /api/public PUBLIC│   │ :8383 /api/did      PUBLIC│◀── did:web
       your apps ──────▶│ :8282 /api/data   │   │ :8282 /api/credentials PUB│◀── peers
                        │ :8383 /api/control│   │ :8181 /api/identity   !!! │
                        └─────────┬─────────┘   │ :8484 /api/sts   internal │
                                  │             └─────────────┬─────────────┘
                                  └──────────┬────────────────┘
                                             ▼
                                ┌────────────────────────┐
                                │ PostgreSQL   HashiCorp │
                                │ (one DB)     Vault     │
                                └────────────────────────┘
```

Four things about this picture are load-bearing:

- **All three runtimes share one PostgreSQL database.** Not a style choice: the
  data-plane's consumer gateway (`/api/data`) reads EDR rows the control-plane
  writes. Split them and that gateway silently answers *"No EDR satisfying
  criterion"* forever.
- **All three runtimes share one Vault.** The identity-hub mints the STS client
  secret into it; the control-plane reads it back by alias. Two Vaults means the
  control-plane never authenticates.
- **The identity-hub is the boot gate.** It reads the participant public key
  from Vault while creating the participant context and throws if the alias is
  absent. Seed Vault before first start, always.
- **`:8181` on the identity-hub is unauthenticated by construction.** This build
  of the image excludes the identity-hub authentication and authorization
  modules. Anyone who reaches that port can create and delete participant
  contexts, read credentials and rotate keys. Never route it publicly.

Out of scope on purpose: federated-catalog, issuer-service, telemetry services
and the Kafka proxy. Those are the dataspace authority's side, or optional
extras. A participant runs exactly the four services above.

---

## Layout

```
compose/                        Docker Compose — the single-host path
  compose.yaml                  5 services, healthchecks, named volumes
  compose.external-datastores.yaml   bring your own PostgreSQL and Vault
  .env.example                  every knob, commented; copy to .env
  config/<service>/*.properties generated by scripts/render-config.sh
scripts/                        bootstrap and operations (compose path)
  up.sh  bootstrap.sh  teardown.sh  smoke-test.sh
  gen-keys.sh  seed-vault.sh  create-database.sh  render-config.sh  did-document.sh
docs/
  prerequisites.md              what you must obtain from EONA-X, and what blocks what
  onboarding.md                 nothing → first successful contract negotiation
  production-notes.md           what the evaluation defaults deliberately are not
```

---

## Quickstart — Docker Compose

Roughly ten minutes, most of it the first boot: the three runtimes migrate the
database together and wait for each other at the migration barrier.

**You need:** Docker Engine with Compose v2, `openssl`, `curl`, `bash`, and the
three connector images. If you have the source:

The kit defaults to the published images:

```
ghcr.io/eona-x/dataspace/control-plane-postgresql-hashicorpvault:latest
ghcr.io/eona-x/dataspace/data-plane-postgresql-hashicorpvault:latest
ghcr.io/eona-x/dataspace/identity-hub-postgresql-hashicorpvault:latest
```

To build from source instead, or to use your own registry:

```bash
cd /path/to/dataspace-ecosystem
./gradlew dockerize          # produces localhost/local/<launcher>:latest
```

and set `EDC_IMAGE_REGISTRY` / `EDC_IMAGE_NAMESPACE` / `EDC_IMAGE_TAG` in
`.env` (or the three `*_IMAGE` overrides) to match.

```bash
git clone <this repository> eona-x-connector-kit
cd eona-x-connector-kit
cp compose/.env.example compose/.env
```

Edit `compose/.env`. For a purely local evaluation the only two you must change
are the placeholder credentials:

```ini
POSTGRES_PASSWORD=<something>
VAULT_TOKEN=<something>
```

Then:

```bash
scripts/up.sh
```

`up.sh` runs `bootstrap.sh` (checks `.env`, starts the bundled PostgreSQL and
Vault, generates a P-256 key pair into `compose/secrets/`, seeds Vault, verifies
the database and its DDL rights, renders `config/*/config.properties`, writes
the DID document), refuses to continue if the images are missing, starts the
three runtimes, and finishes with `smoke-test.sh`.

A healthy first run ends with something like:

```
ok   Vault holds 'participant-signing-key-pub'
ok   identity-hub is ready
ok   DID document served at http://127.0.0.1:38383/api/did/did.json
ok   participant context exists (Identity API answered 200)
ok   STS client secret minted at 'did:web:...-sts-client-secret'
ok   control-plane is ready
ok   management API answers
ok   management API rejects an unauthenticated caller (401)
ok   data-plane is ready
ok   data-plane is registered with the control-plane
ok   STS issued a token — identity, key material and client secret all line up
```

**One restart of the data-plane on first boot is expected, not a fault.** It
registers itself against the control-plane during boot and that call is fatal if
it fails; released from the migration barrier at the same instant as the
control-plane, it sometimes gets there first. `restart: unless-stopped` covers
it.

Where things are, by default (all on loopback):

| | URL |
| --- | --- |
| Management API | `http://127.0.0.1:18181/api/management` (send `x-api-key`) |
| DSP | `http://127.0.0.1:18282/api/dsp` |
| Data-plane public | `http://127.0.0.1:28181/api/public` |
| Consumer gateway | `http://127.0.0.1:28282/api/data` |
| Identity API | `http://127.0.0.1:38181/api/identity` (**unauthenticated**) |
| Credential service | `http://127.0.0.1:38282/api/credentials` |
| DID document | `http://127.0.0.1:38383/api/did/did.json` |
| Vault UI | `http://127.0.0.1:18200` |
| PostgreSQL | `127.0.0.1:15432` (bundled, for your own `psql`) |

The two bundled datastores are deliberately **not** on 5432/8200: on a host
that already runs a PostgreSQL — the most common case — compose would fail
with "port is already allocated" before any of this kit's diagnostics could
say anything useful. Change `POSTGRES_HOST_PORT` / `VAULT_HOST_PORT` in
`.env` if 15432/18200 collide too.

The management API key is in Vault under `management-api-key`, with a copy at
`compose/secrets/management-api-key.txt`.

Stop with `scripts/teardown.sh`; add `--volumes` to destroy the database and
Vault, `--keys` to destroy the participant identity as well.

**This is not yet a participant in a dataspace.** It has no membership
credential, its DID resolves only inside the compose network, and
`AUTHORITY_DID` points at itself. Continue with
[`docs/onboarding.md`](docs/onboarding.md).

### Bring your own PostgreSQL and Vault

Set `POSTGRES_*` and `VAULT_URL` / `VAULT_TOKEN` in `.env`, then:

```bash
scripts/up.sh --external-datastores
# equivalently, by hand:
docker compose -f compose.yaml -f compose.external-datastores.yaml up -d
```

The override requires Compose ≥ 2.24 (it uses `!reset`); the bundled path does
not. What the external instances must provide is in
[`docs/production-notes.md`](docs/production-notes.md).

---

## Configuration reference

The full reference is the commented file
[`compose/.env.example`](compose/.env.example). Every key carries a comment.
This table lists them by area.

### Identity

| What | Compose | EDC setting |
| --- | --- | --- |
| This connector's DID | `PARTICIPANT_DID` | `edc.participant.id`, `edc.iam.issuer.id`, `edc.iam.sts.oauth.client.id` |
| base64url(DID), no padding | `PARTICIPANT_DID_B64` | inside the credential-service URL |
| did:web over https | `DID_WEB_USE_HTTPS` | `edc.iam.did.web.use.https` |
| Dataspace authority DID | `AUTHORITY_DID` | `dse.authority.did` — **boot fails without it** |
| Accepted credential issuers | `TRUSTED_ISSUERS` | `edc.iam.trusted-issuer.<alias>.id` |
| Signing key aliases | `VAULT_ALIAS_PRIVATE_KEY` / `_PUBLIC_KEY` | `edc.iam.sts.privatekey.alias`, `…publickey.alias`, `edc.transfer.proxy.token.*.alias` |
| Verification method fragment | fixed `#my-key` | `edc.iam.sts.publickey.id` |
| STS client secret alias | `STS_CLIENT_SECRET_ALIAS` | `edc.iam.sts.oauth.client.secret.alias` |

### Public URLs (what peers see)

| What | Compose | EDC setting |
| --- | --- | --- |
| Public base | *(four explicit URLs)* | — |
| DSP callback | `PUBLIC_DSP_URL` | `edc.dsp.callback.address` |
| Data-plane public | `PUBLIC_DATAPLANE_PUBLIC_URL` | `edc.dataplane.api.public.baseurl` |
| Credential service | `PUBLIC_CREDENTIALS_URL` | inside `edc.ih.api.superuser.services` |
| DID document | `PUBLIC_DID_URL` | must equal what `PARTICIPANT_DID` resolves to |
| STS token endpoint | `STS_TOKEN_URL` | `edc.iam.sts.oauth.token.url` |
| Data-plane registration | `DPF_SELECTOR_URL` | `edc.dpf.selector.url` |

### Datastores

| What | Compose | EDC setting |
| --- | --- | --- |
| Bundled or external | bundled by default; `compose.external-datastores.yaml` to opt out | — |
| JDBC URL | `POSTGRES_HOST/PORT/DB` + `POSTGRES_JDBC_PARAMS` | `edc.datasource.default.url` |
| DB credentials | `POSTGRES_USER` / `POSTGRES_PASSWORD` | `edc.datasource.default.user` / `.password` |
| Pool size | `DB_POOL_MAX_TOTAL` | `edc.datasource.default.pool.connections.max-total` |
| Vault URL | `VAULT_URL` | `edc.vault.hashicorp.url` |
| Vault token | `VAULT_TOKEN` | `edc.vault.hashicorp.token` |
| KV mount / folder | `VAULT_SECRET_PATH` / `VAULT_FOLDER` | `edc.vault.hashicorp.api.secret.path` / `.folder` |

### Migrations

| What | Compose | EDC setting |
| --- | --- | --- |
| Run migrations | `MIGRATION_ENABLED` | `edc.migration.enabled` |
| Flyway lock retries | `MIGRATION_LOCK_RETRY_COUNT` (240) | `edc.migration.lock.retry.count` |
| **Barrier** | `MIGRATION_BARRIER_EXPECTED_MODULES` | `edc.migration.barrier.expected-modules` |
| Barrier timeout | `…_TIMEOUT_SECONDS` (300) | `edc.migration.barrier.timeout-seconds` |

Schema creation is done in-process by Flyway at boot — no separate migration
step. `edc.sql.schema.autocreate` is forced to `false`. The database role
therefore needs **schema-owner DDL rights**
(`CREATE`/`DROP TABLE`, `DROP INDEX`, `ALTER COLUMN`), not just DML.

**Three** budgets are coupled here, not two. With the barrier active a first
boot has three blocking phases, not one — `FlywayMigrationExtension`
`.migrateBehindBarrier()` runs *own migrations → barrier wait → shared set*,
and each of the two migration phases waits on the Flyway lock separately:

```
phase 1  own migrations   ≤ MIGRATION_LOCK_RETRY_COUNT        (240 s)
phase 2  barrier wait     ≤ MIGRATION_BARRIER_TIMEOUT_SECONDS (300 s)
phase 3  shared set       ≤ MIGRATION_LOCK_RETRY_COUNT        (240 s)
                                             JVM boot          (120 s)
                          ----------------------------------
worst case the settings permit                                 900 s
```

`MIGRATION_BARRIER_TIMEOUT_SECONDS` must be **at least**
`MIGRATION_LOCK_RETRY_COUNT`, or the runtime that finishes phase 1 first can
fail while it sits in the barrier waiting on siblings still queued behind the
Flyway lock — a false failure on a stack where nothing is actually wrong.
Compose does not kill a container over a failed healthcheck, so this worst
case is slow rather than fatal here; `EDC_HEALTHCHECK_START_PERIOD` (360s by
default) only controls when healthcheck failures start counting, which
matters for anything that gates on `depends_on: service_healthy`.

### API exposure and authentication

| What | Compose |
| --- | --- |
| Management API auth | **on by default** (`MANAGEMENT_API_AUTH_ENABLED=true`, header `x-api-key`) |
| API key location | Vault alias `MANAGEMENT_API_KEY_ALIAS` |
| CORS | `CORS_ENABLED` (false) |
| Bind addresses | `BIND_ADDRESS` (loopback) / `PUBLIC_BIND_ADDRESS` |

This is deliberate: compose publishes ports on a host, so it defaults to
authenticated. **If you expose the Management API at all, turn authentication
on.**

### Hyphenated keys, and why there are two config channels

EDC maps an environment variable to a setting by lowercasing it and turning `_`
into `.`. A setting whose key contains a hyphen — `edc.iam.trusted-issuer.<a>.id`,
`edc.migration.barrier.expected-modules`,
`edc.vault.hashicorp.token.scheduled-renew-enabled`,
`edc.datasource.default.pool.connections.max-total`, the state-machine
`iteration-wait-millis` family — can therefore only be expressed as an
environment variable by putting a literal hyphen in the variable's *name* —
which POSIX shells and env files do not accept.

So this kit puts every hyphenated key in `config.properties` (mounted at
`/app/config.properties`, pointed at by `EDC_FS_CONFIG`), and nothing else.
Note the precedence, which is the opposite of what the name suggests:

```
config.properties  <  environment variables  <  -D system properties
```

Anything set as an environment variable **overrides** the file. Do not set the
same key in both channels; keep it that way.
`config.properties` is generated by `scripts/render-config.sh` from `.env` —
edit `.env` and re-render, or put your own additions in
`compose/config/<service>/extra.properties`, which is appended verbatim and
never overwritten.

---

## Troubleshooting

**Identity-hub crash-loops with `Failed to find public key ... in vault`.**
The public key alias is not in Vault, or is not at the path the runtime looks
under. Check the alias name, `VAULT_SECRET_PATH` and `VAULT_FOLDER`, and that
the value is in a field called `content`. Re-run `scripts/seed-vault.sh`.

**Control-plane exits at boot.** Two usual causes, both fatal by design:
`DSE_AUTHORITY_DID` is unset, or a trusted-issuer entry is malformed. A
trusted issuer with properties but no `.id` fails the *whole* boot — there is
no per-issuer degradation.

**Flyway fails with `no value provided for placeholder participantContextId`.**
`EDC_PARTICIPANT_ID` was not set before the first migration. Set it and restart;
it feeds a `NOT NULL` backfill in the 0.15 delta.

**Everything sits doing nothing for minutes on the first boot.** Normal. The
three runtimes are applying their own migrations, signalling on the
`dse_migration_barrier` table and waiting for each other before the shared
migration set is applied. Budget five minutes for a healthy first boot; up to
fifteen in the worst case the default lock and barrier settings permit (see
[Migrations](#migrations)).

**One runtime fails with a barrier timeout** (`Migration barrier timed out
after … waiting for …`). Three causes, in the order worth checking:

1. **A sibling is still queued behind the Flyway lock** — nothing is broken,
   the budget is just wrong. The runtime that finishes its own migrations
   first waits here while the others are still waiting for the lock, so
   `MIGRATION_BARRIER_TIMEOUT_SECONDS` must be **at least**
   `MIGRATION_LOCK_RETRY_COUNT`. Both default to a consistent pair now (300 and
   240); if you lowered the barrier, that is the cause.
2. **A sibling crashed** — look at its log; the barrier message names which
   signal keys are still missing.
3. **A sibling was never going to arrive.** If you deliberately run fewer
   than three runtimes against one database, shorten
   `MIGRATION_BARRIER_EXPECTED_MODULES` to match, or they wait forever for a
   runtime that does not exist.

**The control-plane exits at boot with `No setting found for key
web.http.management.auth.key`.** Management API authentication is on and the
Vault has nothing at the alias. This is a *boot* failure, not a 401: the
runtime resolves the alias from the Vault and, finding nothing, falls back to
a setting that has no default. `scripts/seed-vault.sh` does this for you;
if you changed `MANAGEMENT_API_KEY_ALIAS`, re-run it.

**The data-plane restarted once on first boot.** Expected — see the quickstart.
A restart *loop* is not: check `EDC_DPF_SELECTOR_URL`; it must be the
in-network control-plane address, never the public hostname.

**Control-plane logs STS failures right after a fresh install.** Also expected,
briefly. The client secret does not exist until the identity-hub has created the
participant context once. It recovers by itself; restart it if you are impatient.

**STS failures that do not go away, after the bundled Vault restarted.** This is
the nastiest failure mode in the kit. Dev-mode Vault keeps everything in memory,
so a restart loses the STS client secret — but the identity-hub does *not*
re-mint it, because the participant context still exists in PostgreSQL. The
connector comes back looking healthy and cannot authenticate. Recovery: set
`IH_SUPERUSER_FORCE_RECREATE=true` for **one** boot, then set it back. That
deletes and recreates the participant context, which also destroys stored
credentials — you must request them again.

**`/api/data` answers "No EDR satisfying criterion".** The data-plane is not
reading the database the control-plane wrote the EDR into. Put all three
runtimes back on one database.

**Counterparties cannot resolve your DID.** `did:web:host:a:b:did` is fetched
from `https://host/a/b/did/did.json`. Check that your proxy maps that exact path
onto the identity-hub's DID API (`:8383`, base `/api/did`), that
`DID_WEB_USE_HTTPS` matches reality, and that the document your proxy returns
names your DID.
`scripts/did-document.sh` prints both the expected URL and the document.

**A DID-document service entry is wrong and editing the config changed nothing.**
`EDC_IH_API_SUPERUSER_SERVICES` is applied only when the participant context is
*created*. Changing it later has no effect until the context is recreated (see
`IH_SUPERUSER_FORCE_RECREATE` above, and its cost).

**Management API returns 401/403.** Send the key as the `x-api-key` header, not
as a bearer token. Compose keeps a copy at
`compose/secrets/management-api-key.txt`.

**Management API returns 200 with no credentials.** Authentication is not in
effect. Check `web.http.management.auth.*` in
`config/control-plane/config.properties`, re-render and restart.

**`pull access denied`.** On `localhost/local/…` you have overridden the
defaults and not built the images locally — see the prerequisites. On
`ghcr.io/eona-x/dataspace/…`, either you are behind a proxy that blocks it, or
the packages are still **private**: GHCR creates packages private, and making
them public is a manual step in each package's settings. ghcr.io answers
`denied` for a private package and for a missing one alike, so a login from an
account that is not allowed to read them changes nothing. To tell whether the
packages are public, ask for an anonymous token — it must answer `200`, not `401`:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://ghcr.io/token?scope=repository:eona-x/dataspace/control-plane-postgresql-hashicorpvault:pull"
```

While they are private, authenticate with `docker login ghcr.io` using a GitHub
username and a personal access token with `read:packages`, from an account that
can read the packages, or mirror the images into a registry you control.

**Bundled Vault (non-dev, file storage) comes back sealed.** It has no
auto-unseal. `vault operator unseal` after every restart, then restart the
connectors. This is one of several reasons the bundled Vault is evaluation-only.

**Where to look first, in order:** the identity-hub's log, then the
control-plane's, then the data-plane's. Nearly every failure in this stack is a
boot failure caused by a missing Vault alias or an unreachable database, and it
shows up in the first of the three.

---

## Documentation

- [`docs/prerequisites.md`](docs/prerequisites.md) — what you must obtain from
  EONA-X before deploying, and what is a blocker without them.
- [`docs/onboarding.md`](docs/onboarding.md) — end-to-end runbook from nothing to
  a first successful contract negotiation, marking where EONA-X has to act.
- [`docs/production-notes.md`](docs/production-notes.md) — what the evaluation
  defaults deliberately are not, and what a production deployment must change.

## Licence

Apache-2.0, matching the connector's own code licensing. See [`LICENSE`](LICENSE).

The connector images this kit deploys are built from the EONA-X
`dataspace-ecosystem` distribution of Eclipse Dataspace Components; that project
licenses code under Apache-2.0 and non-code under CC-BY-4.0.
