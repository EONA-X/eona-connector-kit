# Prerequisites

What you must have in hand **before** you deploy anything, who provides it, and
what happens if you do not have it.

The short version: two items require EONA-X and cannot be self-served today.
Everything else is yours.

> **Kubernetes/Helm note:** the Helm chart referenced throughout this document
> is a draft proposal under review, not yet merged into this repository's
> `main` — see the open merge request and
> [eona-x/backlog#322](https://gitlab.eona-x.org/eona-x/backlog/-/issues/322).
> The Docker Compose path is what is available here today.

---

## 1. Summary table

| # | What | Who provides it | Without it |
| --- | --- | --- | --- |
| 1 | **The dataspace authority's DID** | **EONA-X** | **Hard blocker.** The control-plane refuses to boot. |
| 2 | **Holder declaration + attestation at the authority** | **EONA-X** | You boot, you look healthy, and every counterparty rejects you. |
| 3 | Authority host / environment (dev, uat, prod) | EONA-X | You cannot request a credential. |
| 4 | Peer participant DIDs you must verify | EONA-X (or the peers) | Credential verification fails for those peers only. |
| 5 | Your participant DID | **You** (agree the shape with EONA-X) | — |
| 6 | A public hostname, TLS, and a reverse proxy | **You** | Nobody can reach you; did:web does not resolve. |
| 7 | PostgreSQL | **You** | — |
| 8 | HashiCorp Vault | **You** | — |
| 9 | The participant signing key pair | **You** (`scripts/gen-keys.sh`) | Identity-hub will not boot. |
| 10 | STS client secret | **Minted by your own identity-hub** | — (see §5; do *not* ask EONA-X for it) |

---

## 2. The two blockers

### 2.1 The authority's DID

`dse.authority.did` is declared mandatory by the catalog-filtering extension.
The control-plane does not degrade without it — it fails to start.

It looks like `did:web:<authority host>:authority:ih:did` and it differs per
environment. Ask for the DID **and** the environment you are being onboarded
into. Set it as `AUTHORITY_DID`, and list the same DID in the trusted-issuer
list (§2.2).

For a first local evaluation with no dataspace at all, the kit's default points
`AUTHORITY_DID` at your own DID, purely so the runtime boots. That is not a
usable configuration for anything else, and `bootstrap.sh` says so.

### 2.2 Membership: holder declaration and attestation

Your identity-hub cannot give itself a `MembershipCredential`. Issuance is a
three-step exchange, and **the first two steps happen on EONA-X's
issuer-service** (see [`onboarding.md`](onboarding.md) for the exact calls):

1. **Declare holder** — EONA-X registers your DID as a known holder. *EONA-X.*
2. **Deliver attestation** — EONA-X records the membership (or domain)
   attestation for your DID. *EONA-X.*
3. **Request the credential** — your identity-hub asks the authority's issuer
   for the credential and stores it. *You.*

Step 3 fails until steps 1 and 2 have happened, and step 3 also requires that
the authority's issuer-service can **resolve your did:web over the public
internet** — so §4 below is a prerequisite for this one.

There is one further EONA-X-side prerequisite behind all three: the attestation
definitions and credential definitions must already exist on the issuer-service
for that environment. They are created once per environment by EONA-X, not per
participant. If step 3 fails with an unknown credential definition, that is
what is missing.

---

## 3. What you must decide, and tell EONA-X

### 3.1 Your DID

A `did:web`, and it is the identity of the whole connector: participant id,
issuer id, STS client id, and the subject of every credential you hold.
Changing it later means re-onboarding from scratch.

`did:web` resolution is a plain HTTPS GET, and colons after the host become
path segments:

```
did:web:connector.example.org:acme:ih:did
  -> https://connector.example.org/acme/ih/did/did.json

did:web:connector.example.org
  -> https://connector.example.org/.well-known/did.json
```

Pick a host you control and will keep. Agree the shape with EONA-X — their own
participants use `did:web:<host>:<participant>:ih:did`, and matching it keeps
their tooling working without special cases.

### 3.2 Four public endpoints

You need a reverse proxy or ingress controller with a real TLS certificate,
publishing exactly these four routes:

| Route | Target | Who calls it |
| --- | --- | --- |
| DID document, at the exact path the DID resolves to | identity-hub `:8383` `/api/did` | the authority, every counterparty |
| Credential service | identity-hub `:8282` `/api/credentials` | counterparties during DSP |
| DSP | control-plane `:8282` `/api/dsp` | peer connectors |
| Data-plane public API | data-plane `:8181` `/api/public` | consumers fetching data from you |

And these must **not** be publicly routed:

| Never public | Why |
| --- | --- |
| identity-hub `:8181` `/api/identity` | **unauthenticated by construction in this build** — create/delete participant contexts, read credentials, rotate keys |
| control-plane `:8181` `/api/management` | full control of your connector; unauthenticated unless you turn auth on |
| control-plane `:8383` and data-plane `:8383` `/api/control` | unauthenticated internal signalling |
| any `:8080` `/api/check/*` | health probes |
| data-plane `:8282` `/api/data` | consumer gateway; it takes a contract-agreement id as its only credential |

Give EONA-X your DID and your four public URLs. They may need to allowlist you,
and the peers you will trade with need your DID for their own trusted-issuer
lists.

### 3.3 Reachability, in both directions

- The authority's issuer-service must reach your DID document and your identity
  API endpoint during issuance.
- Peer connectors must reach your DSP endpoint and your credential service.
- You must reach the authority's issuer-service and every peer's DSP endpoint.

If your connector sits behind a corporate firewall with no inbound path, that is
a blocker you own, and it will surface as an obscure verification failure rather
than a connection error. Sort it out before onboarding.

---

## 4. Infrastructure you provide

### PostgreSQL

- **One empty database**, shared by all three runtimes. Not three databases: the
  data-plane's consumer gateway reads rows the control-plane writes.
- **A role with schema-owner DDL rights.** Flyway creates, drops and alters
  tables at boot (`CREATE TABLE`, `DROP TABLE`, `DROP INDEX`, `ALTER COLUMN …
  SET NOT NULL`). A read/write-only grant will not boot.
- **No seed SQL.** Everything is created by Flyway.
- Version 16 is what the reference deployment and the bundled evaluation
  instance use.
- Connection budget: each runtime opens its own pool against the same instance,
  so size `poolMaxTotal` × 3 against your quota. Managed instances often cap
  this low; the reference deployment runs with 1 per runtime.
- TLS is yours to configure: put `?sslmode=require` (or stricter) in the JDBC
  URL. If the server presents a private CA, see the custom-CA note below.

`scripts/create-database.sh` checks all of this and tells you precisely what to
ask a DBA for if a grant is missing.

### HashiCorp Vault

**Vault is not optional.** The images are built with the HashiCorp Vault binding
only — there is no filesystem or in-memory variant of these launchers.

- **KV v2**, mounted at `/v1/secret` by default. EDC reads the value from a
  field named `content`: `vault kv put secret/<alias> content=@key.pem`.
- **One Vault for all three runtimes.** The identity-hub mints the STS client
  secret into it and the control-plane reads it back.
- **A token, ideally scoped** to this connector's secret path. The reference
  deployment uses a root token; do not copy that. Note that the identity-hub
  persists this token into the participant-context row of the database, which is
  a further argument for a narrow one. EDC 0.15 also supports AppRole
  (`edc.vault.hashicorp.clientid` / `.clientsecret` / `.tokenurl`) as an
  alternative to a token.
- **Known limitation:** the per-participant vault-config that the runtimes seed
  for themselves hardcodes `/v1/secret` and no folder. A non-default KV mount or
  folder works for the default Vault client and is silently ignored on that
  path. Unless you have verified otherwise on your build, leave the mount at
  `/v1/secret` with an empty folder.
- If your Vault (or your database) presents a **private CA** certificate,
  mount your own truststore and set `JAVA_TOOL_OPTIONS` yourself.

### The participant key pair

One elliptic-curve key pair serves the whole connector: the identity-hub signs
STS tokens and DID proofs with it and publishes the public half in the DID
document; the data-plane signs and verifies transfer-proxy tokens with it.

```bash
scripts/gen-keys.sh          # P-256 (prime256v1), PKCS#8 private + SPKI public
scripts/seed-vault.sh        # loads both into Vault under the configured aliases
```

**A third alias, if you turn Management API authentication on.** It is not
part of the signing key pair. `scripts/seed-vault.sh` generates and seeds it
automatically under `MANAGEMENT_API_KEY_ALIAS` — if the control-plane finds
nothing there it falls back to a setting that has no default, so it fails its
**boot** with `No setting found for key web.http.management.auth.key`, not a
401.

Two things to know:

- The **public key alias is a hard boot gate**. The identity-hub resolves it
  from Vault while creating the participant context and throws if it is absent.
  Seed it before first start, every time.
- Keep the private key somewhere you can restore it from. Regenerating it
  invalidates the published DID document and every signature counterparties have
  seen, and means re-obtaining your credentials.

Do not use a bare organisation name as the alias. Aliases collide in a shared
Vault; `participant-signing-key` (the compose default) is a better habit.

---

## 5. One thing you should *not* ask EONA-X for

**The STS client secret.** In a self-hosted connector it is not an EONA-X
artifact at all: your own identity-hub mints it into your own Vault, under the
alias `<your DID>-sts-client-secret`, at the moment it first creates the
participant context. Your control-plane then reads it back from the same Vault
by alias. It never crosses an organisational boundary.

This matters for two reasons:

- It creates a **boot order** on a fresh install: seed the key pair → start the
  identity-hub → the control-plane can then obtain tokens. Before that, the
  control-plane logs STS failures. This is normal and self-correcting.
- If the secret is ever lost while the participant context survives — exactly
  what happens when a dev-mode Vault restarts — the identity-hub will **not**
  re-mint it, and the connector comes back looking healthy but unable to
  authenticate. Recovery requires recreating the participant context. See
  [`production-notes.md`](production-notes.md).

(The only case where the STS client secret comes from EONA-X is a
connector-as-a-service arrangement where they operate your identity-hub. That is
not the topology this kit deploys.)

---

## 6. Tooling on the machine you deploy from

| Needs |
| --- |
| `bash`, `curl`, `openssl`, `base64` |
| Docker Engine + **Compose v2**; **v2.24+** only if you use `compose.external-datastores.yaml` (it uses `!reset`) |
| Optional: the `vault` CLI (the scripts use the HTTP API, so it is a convenience) |

---

## 7. Readiness checklist

Do not start until you can tick all of these:

- [ ] You can `docker pull` (or have built) all three connector images, and you
      know which tag you should be running.
- [ ] You have the authority's DID and know which environment it belongs to.
- [ ] You have chosen your `did:web` and can serve
      `https://<host>/<path>/did.json` from your proxy.
- [ ] You have a public hostname with a valid TLS certificate, and can route the
      four public paths — and only those four.
- [ ] You have an empty PostgreSQL database and a role with DDL rights on it.
- [ ] You have a Vault with KV v2, and a token for it.
- [ ] You have generated the key pair and know where the private key is backed
      up.
- [ ] Both key aliases are **in the Vault** — the public one is a hard boot
      gate for the identity-hub.
- [ ] If you are turning Management API authentication on:
      `MANAGEMENT_API_KEY_ALIAS` is in the Vault too. Missing, it fails the
      control-plane's boot, not the request.
- [ ] EONA-X knows your DID and your public URLs, and has agreed to declare you
      as a holder.

Then go to [`onboarding.md`](onboarding.md).
