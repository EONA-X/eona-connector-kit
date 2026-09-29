# Production notes

What the defaults in this kit deliberately are **not**, and what you have to
change before this carries anything that matters.

The evaluation defaults exist so that someone can have a connector answering
within an afternoon, on a laptop, with no dataspace and no infrastructure. Every
one of them trades something away. This document lists the trades.

> **Kubernetes/Helm note:** the Helm chart referenced throughout this document
> is a draft proposal under review, not yet merged into this repository's
> `main` — see the open merge request and
> [eona-x/backlog#322](https://gitlab.eona-x.org/eona-x/backlog/-/issues/322).
> The Docker Compose path is what is available here today.

---

## 1. At a glance

| Default | What it actually is | Production requires |
| --- | --- | --- |
| Bundled PostgreSQL (`postgresql.bundled`, compose default) | one pod/container, no backup, no failover, no TLS, password from a values file | an operated PostgreSQL: backups, PITR, TLS, monitoring |
| Bundled Vault in dev mode | **in-memory storage**, fixed root token, no TLS, auto-unseal | an operated Vault: persistent storage, HA or auto-unseal, TLS, a scoped token |
| Bundled Vault with file storage | persistent, but a single node with **no auto-unseal** | the same |
| `CHANGEME` placeholders | the chart installs with them; nothing fails fast | real values; check `helm get notes` for survivors |
| Chart-created Secrets | credentials pass through values files and Helm release storage | `postgresql.existingSecret` and `vault.token.existingSecret` |
| Root Vault token | persisted into the `participant_context` database row by the identity-hub | a token scoped to this connector's secret path, or AppRole |
| Management API unauthenticated (Helm default) | protected only by not being routed | `authType: tokenbased` with a Vault-held key |
| Identity API unauthenticated | **cannot be fixed by configuration** — the modules are excluded from the image | your own gateway in front, and never public |
| `replicaCount: 1` everywhere | no redundancy; a node drain is an outage | see §6 — read it before scaling |
| No Ingress, `ClusterIP` only | nothing is reachable | your own gateway, publishing exactly four routes |
| OpenTelemetry agent disabled | no traces, no metrics export | enable it and point it at your collector |
| No backups, no PDB, no NetworkPolicy, no HPA | the chart creates none of these | yours to add |
| Credential **revocation checks are bypassed** | see §10 — a build-level property, not a setting | understand the exposure; raise it with EONA-X |

---

## 2. PostgreSQL

The bundled instance is a single Deployment with a `Recreate` strategy, a
PersistentVolumeClaim (or, in `values-minimal.yaml`, an `emptyDir` that loses
the database on every pod restart) and credentials from a values file. It has no
backup, no replica, no connection limits and no TLS. It exists so the chart can
be installed on an empty cluster. Nothing more.

What an operated instance must provide:

- **One empty database** shared by all three runtimes. This is not negotiable:
  the data-plane's consumer gateway reads EDR rows the control-plane writes.
  Separate databases break `/api/data` silently, with the message *"No EDR
  satisfying criterion"*.
- **A role with schema-owner DDL rights.** Flyway creates, drops and alters
  tables at boot. A read/write-only grant will not boot.
- **Backups with point-in-time recovery.** The database holds your contract
  agreements, your transfer history and your participant context. Losing it is
  not a matter of re-running a migration.
- **TLS** — `?sslmode=require` at minimum, `verify-full` if you can. If the
  server uses a private CA, enable the kit's custom-CA block rather than
  disabling verification.
- **A connection budget you have actually counted.** Each runtime opens its own
  pool: the real number is `poolMaxTotal × 3`. The reference deployment runs
  with 1 per runtime because the managed instance behind it has a low cap.
- **Monitoring on the `flyway_schema_history` table and on lock waits.** There
  is one history table per database, shared by all three runtimes.

---

## 3. HashiCorp Vault

Vault is not optional in this architecture — the images are built with the
HashiCorp binding only. Whatever you do about the rest, you are running a Vault.

### The dev-mode trap

`vault server -dev` keeps everything **in memory**. When that container or pod
restarts:

- the participant key pair is gone (recoverable: `scripts/bootstrap.sh` re-seeds
  the same keys from `compose/secrets/`);
- the **STS client secret is gone and is not re-minted**, because the identity-hub
  only mints it when it *creates* the participant context — and the context is
  still there, in PostgreSQL.

The result is the worst shape a failure can take: the connector comes back,
reports healthy, and cannot authenticate to anything. The only recovery is to
recreate the participant context (`IH_SUPERUSER_FORCE_RECREATE=true` for one
boot, or `identityHub.participantContext.forceRecreate=true`), which **destroys
the stored credentials and key-pair records** — you then have to request every
credential from the issuer again.

The file-storage variant (`vault.dev: false`) is persistent but has no
auto-unseal: every restart leaves it sealed until a human unseals it, and every
alias lookup fails meanwhile.

### What a production Vault needs

- Persistent, backed-up storage, and HA or auto-unseal. A sealed Vault is a
  total outage for the connector.
- TLS, with the CA in the JVMs' trust store (`tls.customCa.enabled` in the
  chart turns on the init container, the CA volume and the JVM truststore flags
  as a single unit — there is no way to end up pointed at a truststore that was
  never created).
- **A scoped token**, not a root token. The reference deployment uses the root
  token; do not copy that. It matters more than usual here, because the
  identity-hub writes this token into the participant's vault-config and it can
  land in the `participant_context` row of the database. EDC 0.15 also supports
  AppRole (`edc.vault.hashicorp.clientid` / `.clientsecret` / `.tokenurl`) —
  exactly one of the two mechanisms may be configured.
- Audit logging, and a rotation plan for the token and the key pair.
- **Leave the KV mount at `/v1/secret` with an empty folder** unless you have
  verified otherwise. The per-participant vault-config that the runtimes seed
  for themselves hardcodes that path, so a custom mount is honoured by the
  default client and silently ignored on the per-participant path. The kit
  exposes the values and documents the limitation rather than pretending it
  works.

### What lives in Vault, and what must never leave it

| Secret | Where it lives | Notes |
| --- | --- | --- |
| Participant private key | Vault only | one pair serves identity-hub and data-plane |
| Participant public key | Vault only | **hard boot gate** for the identity-hub |
| STS client secret | Vault only | minted by the identity-hub; never crosses a boundary |
| Management API key | Vault (alias in config) | the alias is not a secret; the value never enters Kubernetes |
| Database username/password | Kubernetes Secret / `.env` | `secretKeyRef` only, never a ConfigMap |
| Vault token | Kubernetes Secret / `.env` | `secretKeyRef` only |
| Registry pull secret | Kubernetes Secret | only if your images are private |

Everything else — DIDs, aliases, URLs, the trusted-issuer list — is
non-sensitive and belongs in the ConfigMap. Keep it that way.

---

## 4. Secrets handling

- **Use `existingSecret`.** With `postgresql.existingSecret` and
  `vault.token.existingSecret` set, the chart renders no credential at all:
  nothing sensitive lands in a values file, in your Git history, or in Helm's
  release storage (where `helm get values` and anyone with read access to the
  release secret can see it).
- **Placeholders do not fail the install.** `values.yaml` ships `CHANGEME`
  strings, and Helm cannot distinguish a placeholder from a hostname. `required`
  guards only catch an explicitly nulled value, because stricter guards would
  break `helm lint` against the chart's own defaults. The post-install notes
  list every surviving `CHANGEME` — read them, every time.
- **The compose path writes real secrets to disk** under `compose/secrets/`:
  the private key (mode 600), the management API key, and the generated DID
  document. That directory is gitignored. Treat it as key material: back up the
  private key, and do not copy the directory around casually.
- `compose/.env` holds the database password and the Vault token in plain text.
  It is gitignored. On a shared host, mind its permissions.

---

## 5. Network exposure

Exactly four things belong on the public internet:

| Public | Component | Port | Who calls it |
| --- | --- | --- | --- |
| DSP | control-plane | 8282 | peer connectors |
| Data-plane public API | data-plane | 8181 | consumers pulling your data |
| Credential service | identity-hub | 8282 | counterparties during DSP |
| DID document | identity-hub | 8383 | everybody, at exactly the DID's URL |

Everything else must be unreachable from outside:

- **Identity API (identity-hub `:8181`)** — unauthenticated *by construction*:
  this build excludes the identity-hub authentication and authorization
  modules, so there is no configuration that protects it. Anyone who reaches it
  can create and delete participant contexts, read credentials and rotate keys.
  It needs your own gateway with your own authentication, on your own network.
  The chart's notes warn if you route it through an Ingress; take the warning
  seriously.
- **Management API (control-plane `:8181`)** — full control of your connector.
  Turn authentication on (`authType: tokenbased` plus a Vault alias) *and* keep
  it off the internet. The compose path defaults it on; the Helm chart defaults
  it off to match the runtime, and says so in the notes.
- **Control APIs (`:8383` on both control-plane and data-plane)** —
  unauthenticated internal signalling.
- **Consumer gateway (data-plane `:8282` `/api/data`)** — its only credential is
  a contract-agreement id. It belongs on your side of the perimeter.
- **Health contexts (`:8080`)** — probes only.

Other things to settle:

- **TLS terminates at your gateway.** The connector speaks plain HTTP on all
  ports. Nothing in this kit terminates TLS.
- **The DID path mapping is load-bearing.** `did:web:host:a:b:did` must resolve
  at `https://host/a/b/did/did.json`. Use `publicPathPrefix` plus
  `endpoints.did.publicPath` so that `/api` does not leak into the DID itself.
- **CORS is off by default**, and `"*"` headers on an authenticated API is not a
  posture to adopt casually. Narrow it if you enable it.
- The chart creates **no NetworkPolicy**. If your cluster enforces them, you
  need policies allowing control-plane ↔ data-plane ↔ identity-hub and all three
  → PostgreSQL and Vault.

---

## 6. Availability, scaling and upgrades

**`replicaCount` is 1 for all three runtimes, in the chart and in the reference
deployment.** The runtimes are stateless — everything is in PostgreSQL and
Vault — and EDC leases state-machine work through the `edc_lease` table, so more
than one replica is architecturally possible. It is **not validated by this kit
and not run that way in the reference deployment**. If you need HA, treat it as
a piece of work with its own testing, not as a value change.

What that means today: a node drain or a pod restart is a short outage. Mitigate
with `PodDisruptionBudget`s and sensible scheduling (the chart exposes
`nodeSelector`, `tolerations`, `affinity` per component) rather than by
optimistically raising replicas.

**Migrations run in-process at boot.** There is no Job, no init container and no
Helm hook. That is a deliberate design, and it has consequences:

- The **startup probe is the boot budget**, and it must cover the whole of
  what the migration settings permit — which is three blocking phases, not
  one. `FlywayMigrationExtension.migrateBehindBarrier()` runs *own migrations
  → barrier wait → shared set*, and each of the two migration phases waits on
  the Flyway lock separately, so the worst case the defaults allow is

  ```
  2 × lockRetryCount (240) + barrier.timeoutSeconds (300)
                           + bootAllowanceSeconds  (120)  =  900 s
  ```

  Two orderings follow, and the chart enforces the second by construction:

  ```
  barrier.timeoutSeconds  >=  lockRetryCount
  startup probe budget    >=  2 × lockRetryCount + barrier.timeoutSeconds
                              + bootAllowanceSeconds
  ```

  The first stops the *fastest* runtime failing its boot while a sibling is
  still queued behind the lock. The second stops Kubernetes killing a pod
  that is migrating correctly. Leave
  `<component>.startupProbe.failureThreshold` empty and the chart derives it
  from those three values, so they cannot drift; lower `lockRetryCount` and
  the probe shrinks with it. The compose path now budgets the same stack the
  same way (`MIGRATION_LOCK_RETRY_COUNT=240`,
  `MIGRATION_BARRIER_TIMEOUT_SECONDS=300`) — though compose never kills a
  container on a failed healthcheck, so only Kubernetes is exposed to getting
  this wrong.
- The three runtimes share one `flyway_schema_history` table and serialise on
  the Flyway lock. The last to start waits for the others.
- The **migration barrier** — the list of every migration-contributing runtime
  on that database — is computed automatically by the chart and set explicitly
  in the compose config. Do not clear it while the runtimes share a database:
  the shared migration reshapes `edc_lease` destructively while the other
  runtimes' baselines still create foreign keys into it.
- Some migration steps **are destructive** (`DROP TABLE edc_lease CASCADE`,
  dropped `lease_id` columns, dropped key-alias columns on `edc_sts_client`).
  **Take a database backup before every image upgrade**, and read the upgrade
  notes that come with the image.
- An image upgrade is therefore a coordinated event, not a rolling one: all
  three runtimes must be on compatible migration sets, and they must all be
  running for the barrier to clear.

`resources` defaults are modest (250 m / 512 Mi requested, 2 CPU / 1 Gi limit).
These are JVMs: raise memory before CPU, and measure. On OpenShift with the
`restricted-v2` SCC, clear `runAsUser`, `runAsGroup` and `fsGroup` (set them to
null) and let the platform assign a UID — the images do not care which UID they
run as.

---

## 7. Backup and recovery

Three things, with very different characters:

| What | Loss means | Back up how |
| --- | --- | --- |
| **The participant private key** | your identity is gone: new key → new DID document → every counterparty must re-resolve, the authority must re-attest, credentials must be re-issued | offline copy of the PEM, treated as a root credential |
| **The database** | contract agreements, transfer history, participant context | PostgreSQL backups with PITR |
| **Vault contents** | key pair (restorable from the offline copy) and the STS client secret (**not** re-minted while the participant context survives) | Vault's own snapshot mechanism |

Restore order after a full loss: Vault (keys) → database → connectors. If the
database survived but Vault did not, restore the keys to the *same aliases*
before starting the identity-hub, and expect to have to recreate the participant
context if the STS client secret cannot be restored — which costs you the stored
credentials.

---

## 8. Observability

- The OpenTelemetry agent is attached to every image and **disabled by default**
  via `/app/opentelemetry.properties`. Enable it there and point it at your
  collector; the file is a chart value (`<component>.opentelemetry`) and a
  mounted file on compose.
- Logging is `java.util.logging` configured by `/app/logging.properties`, also a
  value. The chart defaults to `INFO`; `values-minimal.yaml` and the reference
  deployment run `DEBUG`, which is far too chatty for production.
- Health endpoints are `/api/check/{startup,liveness,readiness}` on `:8080`. The
  images declare `HEALTHCHECK NONE`, so the compose file supplies its own.
- Nothing scrapes metrics by default. The runtimes carry Micrometer
  instrumentation; wiring it to your monitoring is yours.
- The data-plane writes a usage row to `edc_telemetry_record` for every request
  through its public and data contexts. That table grows without bound; plan
  housekeeping.
- Watch for these specifically: Flyway lock waits at boot, STS token failures,
  data-plane registration failures, and Vault health-check failures.

---

## 9. Images and supply chain

- Tags are **build dates** (`20260911-0900`), not versions. Pin an exact tag;
  `latest` is for locally built images only. The chart deliberately does not
  fall back to `Chart.appVersion`, because that string names no real tag.
- Mirror the images into your own registry if your policy requires it, and
  build from source if you would rather not depend on someone else's registry
  being up when you scale out.
- The containers run as non-root uid/gid 1000 and need a writable temp
  directory, so `readOnlyRootFilesystem` is not set.
- `imagePullSecrets` defaults to empty. Set it only if your registry is private.

---

## 10. Known limitations of this kit and this build

Stated plainly, because finding them yourself at 2 a.m. is worse:

1. **Credential revocation checks are bypassed.** The connector build registers
   a no-op revocation service for StatusList2021 and BitstringStatusList. A
   revoked credential will still verify. This is a property of the image, not a
   setting in this kit; if it matters to your risk posture, raise it with
   EONA-X.
2. **The Identity API cannot be authenticated** in this build (§5).
3. **No EDC runtime has been started against this kit's configuration.** It is
   derived from the running reference deployment and verified against the EDC
   0.15.0 artifacts, and the datastore/bootstrap half has been run for real, but
   the first person to boot it with real images is doing the first real boot.
4. **Authority onboarding is not automated here.** Declaring a holder and
   delivering an attestation happen on EONA-X's issuer-service; the kit
   documents the calls ([`onboarding.md`](onboarding.md)) rather than scripting
   them.
5. **A non-default Vault KV mount or folder only half-works** (§3).
6. **The data-plane restarts once on a first boot**, by design, because its
   self-registration against the control-plane is fatal on failure and the
   migration barrier releases both at the same instant.
7. **The two paths differ on one security default**: compose turns management
   API authentication on; the Helm chart leaves it off to match the runtime.
   Decide deliberately, do not inherit.
8. **No HPA, PDB, NetworkPolicy or backup machinery** is generated by the chart.
9. `values-minimal.yaml` disables PostgreSQL persistence so an install does not
   hang on a cluster with no default StorageClass. That database is wiped on
   every pod restart. It is for demos.

---

## 11. Production checklist

- [ ] External PostgreSQL, backed up, TLS, DDL-capable role, connection budget
      counted.
- [ ] External Vault: persistent, TLS, HA or auto-unseal, **scoped token**,
      audited.
- [ ] `postgresql.existingSecret` and `vault.token.existingSecret` set; no
      credential in any values file.
- [ ] No `CHANGEME` left — confirmed against `helm get notes`.
- [ ] Image tag pinned to an exact build; pull secret in place if needed.
- [ ] Exactly four public routes; management API, identity API, control APIs and
      health ports unreachable from outside.
- [ ] Management API authentication on, key held in Vault — and **the alias
      actually seeded**. `authType: tokenbased` with nothing at
      `authKeyAlias` fails the control-plane *boot*, not the request.
- [ ] DID resolves over HTTPS from outside your network, at the exact path the
      DID encodes.
- [ ] Migration barrier active (it is, by default, when the database is
      shared); `barrier.timeoutSeconds >= lockRetryCount`, and the
      startup-probe budget at or above
      `2 × lockRetryCount + barrier.timeoutSeconds + bootAllowanceSeconds`
      (automatic unless you pinned `startupProbe.failureThreshold`).
- [ ] Private key backed up offline; database and Vault backups scheduled and
      *restored once* as a test.
- [ ] Logging at `INFO`, OpenTelemetry pointed at a collector, alerts on boot
      failures and STS failures.
- [ ] A rehearsed upgrade procedure: backup → upgrade all three runtimes
      together → verify with the smoke test.
