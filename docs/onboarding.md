# Onboarding runbook

From nothing to a first successful contract negotiation.

Each phase says who acts. **[YOU]** is you; **[EONA-X]** is a step only the
dataspace operator can perform, and which blocks everything after it.

| Phase | | What |
| --- | --- | --- |
| 0 | [YOU] + [EONA-X] | Prerequisites |
| 1 | [YOU] | Decide identity and public URLs |
| 2 | [YOU] | Key material, Vault, database |
| 3 | [YOU] | Deploy and get the connector answering |
| 4 | [YOU] | Make the DID resolve from the outside |
| 5 | **[EONA-X]** | Declare holder, deliver attestation |
| 6 | [YOU] | Request the membership credential |
| 7 | [YOU] | Point at the real authority and trusted issuers |
| 8 | [YOU] | Publish an asset, a policy, a contract definition |
| 9 | [YOU] | First negotiation and transfer |

Phases 1–4 can be rehearsed entirely offline with the bundled evaluation stack.
Phase 5 is where the dataspace becomes involved, and it is the one with a lead
time you do not control.

> **Kubernetes/Helm note:** the Helm chart referenced throughout this runbook
> is a draft proposal under review, not yet merged into this repository's
> `main` — see the open merge request and
> [eona-x/backlog#322](https://gitlab.eona-x.org/eona-x/backlog/-/issues/322).
> The Docker Compose path is what is available here today.

---

## Phase 0 — Prerequisites

Work through [`prerequisites.md`](prerequisites.md) and do not start until its
checklist is ticked. The two things people discover too late:

- **You need the authority's DID**, or the control-plane will not start at all.
- **Membership does not self-serve.** The authority must declare you as a
  holder and deliver an attestation before you can request a credential.

---

## Phase 1 — Decide identity and public URLs  **[YOU]**

Fix these before you deploy anything. Changing your DID afterwards means
re-onboarding from the beginning.

```
DID                 did:web:connector.example.org:acme:ih:did
DID document at     https://connector.example.org/acme/ih/did/did.json
DSP                 https://connector.example.org/acme/cp/dsp
Credential service  https://connector.example.org/acme/ih/credentials
Data-plane public   https://connector.example.org/acme/dp/public
```

The DID and the DID-document URL must correspond exactly: `did:web` resolution
turns the colons after the host into path segments and appends `/did.json`.

Compute the base64url-no-padding form of your DID once; you will need it in
several URLs:

```bash
printf '%s' "$PARTICIPANT_DID" | base64 | tr -d '\n=' | tr '+/' '-_'
```

(Compose keeps it in `.env` as `PARTICIPANT_DID_B64` and `bootstrap.sh` verifies
it. Helm derives it.)

Send your DID and the four URLs to EONA-X now — phase 5 needs them, and it is
the step with a queue in front of it.

---

## Phase 2 — Key material, Vault, database  **[YOU]**

```bash
scripts/gen-keys.sh        # P-256 pair into compose/secrets/
scripts/seed-vault.sh      # loads both halves into Vault, generates the mgmt API key
scripts/create-database.sh # checks the database exists and the role can run DDL
```

Those three scripts read `compose/.env`, so on the Kubernetes path generate the
pair directly — it is the same P-256 shape — and load it into your own Vault
under the aliases the chart will use (`helm get notes` or `helm template`
prints them):

```bash
openssl ecparam -name prime256v1 -genkey -noout -out ec.pem
openssl pkcs8 -topk8 -nocrypt -in ec.pem -out private.pem   # PKCS#8
openssl ec -in ec.pem -pubout -out public.pem               # SubjectPublicKeyInfo

vault kv put secret/<privateKeyAlias> content=@private.pem
vault kv put secret/<publicKeyAlias>  content=@public.pem
```

EDC reads the value from a field named `content`; any other field name resolves
to nothing.

The public key alias is a hard boot gate: without it the identity-hub throws
during startup and the pod crash-loops. Back up the private key somewhere you
can restore it from.

---

## Phase 3 — Deploy  **[YOU]**

**Compose:**

```bash
cp compose/.env.example compose/.env
$EDITOR compose/.env            # DID, authority DID, public URLs, credentials, images
scripts/up.sh                   # bootstrap + start + smoke test
```

**Kubernetes:**

```bash
helm install acme ./charts/participant-connector -f my-values.yaml
helm get notes acme             # checks for surviving CHANGEME placeholders
helm test acme
```

What the first boot looks like, so you do not misread it:

1. All three runtimes start together. They must: each applies its own Flyway
   migrations, records its signal key on a coordination table and waits for the
   others before the shared migration set is applied. Chaining them would
   deadlock.
2. Nothing answers HTTP for a few minutes. Migrations run before the web server
   starts.
3. The data-plane may exit once and restart. It registers itself against the
   control-plane during boot and that call is fatal if it fails; released from
   the barrier at the same moment, it can get there first. **One restart is
   acceptable and so is none; a restart loop is not.**
4. The control-plane logs STS failures until the identity-hub has created the
   participant context once — that is when the STS client secret is minted into
   Vault. It recovers on its own.

Then verify:

```bash
scripts/smoke-test.sh           # compose
helm test acme                  # kubernetes
```

The most informative single check is the last one in the smoke test: the STS
issuing a token. It exercises the participant context, the private key in Vault
and the client secret in one call. If that passes, your identity plumbing is
sound.

**What this does not prove:** that you are a member of a dataspace. That is
phases 5 and 6.

---

## Phase 4 — Make the DID resolve  **[YOU]**

Two ways to serve the document, and both are acceptable:

- **Route to the identity-hub.** It serves the document on its DID API
  (`:8383`, base path `/api/did`). Your proxy maps the DID's public path onto
  it. This is what the reference deployment does, and it keeps the document in
  step with the participant context automatically.
- **Serve a static file.** `scripts/did-document.sh` builds the document from
  the generated public key and prints the exact URL it must be served at.

Verify from **outside your network** — not from the host running the connector:

```bash
curl -fsS https://connector.example.org/acme/ih/did/did.json | jq .
```

You should get a document whose `id` is your DID and whose `service` array
contains two entries:

- `DSPMessaging` → your public DSP URL
- `CredentialService` → your public credential-service URL, ending in
  `/v1/participants/<base64url-no-pad of your DID>`

If a service entry is wrong, note this before you try to fix it by editing
config: those entries are written **only when the participant context is
created**. Changing `EDC_IH_API_SUPERUSER_SERVICES` afterwards has no effect
until the context is recreated, which destroys stored credentials. Get it right
before phase 5.

The authority cannot register you if this URL does not resolve from its network.

---

## Phase 5 — Declare holder and deliver attestation  **[EONA-X]**

**This is the step you cannot perform.** EONA-X runs it against their
issuer-service. It is reproduced here so you know what to ask for and can read
their output when something fails. Their own script is
`edc-participant-setup/scripts/onboard-participant.sh`.

With `AUTHORITY_DID_B64` = base64url-no-pad of the authority's DID:

```bash
# 1. Declare you as a holder
curl -X POST \
  "https://<authority host>/<authority>/is/issueradmin/v1alpha/participants/${AUTHORITY_DID_B64}/holders" \
  -H 'content-type: application/json' \
  -d '{
        "holderId": "did:web:connector.example.org:acme:ih:did",
        "did":      "did:web:connector.example.org:acme:ih:did",
        "name":     "acme"
      }'

# 2. Deliver the membership attestation
curl -X POST \
  "https://<authority host>/<authority>/is/issueradmin/v1alpha/participants/${AUTHORITY_DID_B64}/attestation-membership" \
  -H 'content-type: application/json' \
  -d '{
        "id":             "did:web:connector.example.org:acme:ih:did",
        "name":           "acme",
        "holderId":       "did:web:connector.example.org:acme:ih:did",
        "membershipType": "FullMember"
      }'
```

A domain credential, if your use case needs one, is the same call against
`…/attestation-domain` with a `domain` value.

What to give EONA-X for this step: your DID, a short participant name, the
credential types you need, and your four public URLs. What to get back: the
authority's DID, the authority host and environment, and the **credential
definition ids** in that environment (phase 6 needs them).

Behind this step there is a further EONA-X-side prerequisite, done once per
environment rather than per participant: the attestation definitions and
credential definitions must exist on the issuer-service. A failure in phase 6
naming an unknown credential definition means that is missing.

---

## Phase 6 — Request the credential  **[YOU]**

Your identity-hub asks the authority's issuer for the credential and stores it.
The call goes to **your own** Identity API — which is unauthenticated in this
build, so make it from inside your perimeter (localhost, or
`kubectl port-forward`), never across the internet.

```bash
PARTICIPANT_DID="did:web:connector.example.org:acme:ih:did"
DID_B64=$(printf '%s' "$PARTICIPANT_DID" | base64 | tr -d '\n=' | tr '+/' '-_')
AUTHORITY_DID="did:web:authority.example.org:authority:ih:did"

# compose: identity API on 127.0.0.1:38181
curl -X POST \
  "http://127.0.0.1:38181/api/identity/v1alpha/participants/${DID_B64}/credentials/request" \
  -H 'content-type: application/json' \
  -d "{
        \"issuerDid\": \"${AUTHORITY_DID}\",
        \"holderPid\": \"${PARTICIPANT_DID}\",
        \"credentials\": [
          { \"id\": \"membership-credential-def-1\",
            \"type\": \"MembershipCredential\",
            \"format\": \"VC1_0_JWT\" }
        ]
      }"
```

On Kubernetes:

```bash
kubectl port-forward svc/acme-participant-connector-identityhub 8181:8181
# then the same call against http://127.0.0.1:8181/api/identity/...
```

`membership-credential-def-1` is the id EONA-X uses in their reference
environment. **Confirm the real id for your environment** — it is one of the
things to ask for in phase 5.

Issuance is asynchronous. Check that the credential arrived:

```bash
curl -s "http://127.0.0.1:38181/api/identity/v1alpha/participants/${DID_B64}/credentials" | jq .
```

You are looking for a `MembershipCredential` whose issuer is the authority's
DID and whose subject is yours.

If this is empty after a minute:

- Can the authority's issuer resolve your DID? (Phase 4, from *their* network.)
- Did phases 5.1 and 5.2 actually succeed? Ask for the HTTP status they got.
- Is the credential definition id right?
- Your identity-hub log will name the issuer endpoint it called and what came
  back.

---

## Phase 7 — Point at the real authority  **[YOU]**

Until now you may have been running with placeholder values so the runtime
would boot. Replace them:

**Compose** (`compose/.env`):

```ini
AUTHORITY_DID=did:web:authority.example.org:authority:ih:did
TRUSTED_ISSUERS="authority=did:web:authority.example.org:authority:ih:did"
```

```bash
scripts/render-config.sh                       # regenerate config.properties from .env
cd compose && docker compose up -d --force-recreate control-plane
```

**Helm:**

```yaml
participant:
  authority:
    did: "did:web:authority.example.org:authority:ih:did"
  trustedIssuers:
    - alias: authority
      id: "did:web:authority.example.org:authority:ih:did"
    - alias: partner                      # peers whose credentials you verify
      id: "did:web:connector.partner.example:partner:ih:did"
```

```bash
helm upgrade acme ./charts/participant-connector -f my-values.yaml
```

Two warnings on the trusted-issuer list:

- A malformed entry — properties without a matching `.id` — fails the **whole**
  control-plane boot. There is no per-issuer degradation. Add entries one at a
  time if you are unsure.
- The list is not only the authority. Anyone whose credentials you must verify
  belongs in it, which in practice means your trading peers as well.

Confirm the control-plane came back up before going on.

---

## Phase 8 — Publish something  **[YOU]**

All of this is the Management API. With authentication on (the compose default)
every call carries `x-api-key`:

```bash
MGMT=http://127.0.0.1:18181/api/management

# The key goes into a 0600 curl config file, NOT onto the command line.
# Anything handed to curl as an argument is readable by every local user
# through /proc/<pid>/cmdline and `ps -eo args` for as long as the call
# lasts. `curl --config` keeps it out of the process table; the kit's own
# scripts use the same idiom (secret_curl in scripts/lib/common.sh).
CURLRC=$(mktemp) && chmod 600 "$CURLRC"
printf 'header = "x-api-key: %s"\n' \
  "$(cat compose/secrets/management-api-key.txt)" > "$CURLRC"
AUTH=(--config "$CURLRC" -H 'content-type: application/json')

# ...and when you are finished:  rm -f "$CURLRC"
```

**An asset** — a pointer to data you already serve somewhere:

```bash
curl -X POST "${MGMT}/v3/assets" "${AUTH[@]}" -d '{
  "@context": { "@vocab": "https://w3id.org/edc/v0.0.1/ns/" },
  "@id": "demo-asset-1",
  "properties": { "name": "Demo dataset", "contenttype": "application/json" },
  "dataAddress": {
    "type": "HttpData",
    "baseUrl": "https://data.internal.example.org/demo",
    "proxyPath": "true",
    "proxyQueryParams": "true"
  }
}'
```

**A policy.** An unconstrained one is fine to prove the plumbing:

```bash
curl -X POST "${MGMT}/v3/policydefinitions" "${AUTH[@]}" -d '{
  "@context": {
    "@vocab": "https://w3id.org/edc/v0.0.1/ns/",
    "odrl": "http://www.w3.org/ns/odrl/2/"
  },
  "@id": "open-policy",
  "policy": { "@type": "odrl:Set", "odrl:permission": [], "odrl:prohibition": [], "odrl:obligation": [] }
}'
```

In a real dataspace you do not publish with an open policy. Access is normally
constrained on a verifiable credential — typically requiring the counterparty to
hold a `MembershipCredential` issued by the authority. The connector's own
policy extensions define the constraint vocabulary; ask EONA-X for the policy
shapes in use in your dataspace, and treat the open policy above strictly as a
first smoke test.

**A contract definition** ties the two together and makes the asset visible in
your catalogue:

```bash
curl -X POST "${MGMT}/v3/contractdefinitions" "${AUTH[@]}" -d '{
  "@context": { "@vocab": "https://w3id.org/edc/v0.0.1/ns/" },
  "@id": "demo-contract-1",
  "accessPolicyId": "open-policy",
  "contractPolicyId": "open-policy",
  "assetsSelector": []
}'
```

Check your own catalogue renders:

```bash
curl -X POST "${MGMT}/v3/catalog/request" "${AUTH[@]}" -d "{
  \"@context\": { \"@vocab\": \"https://w3id.org/edc/v0.0.1/ns/\" },
  \"counterPartyAddress\": \"${PUBLIC_DSP_URL}\",
  \"counterPartyId\": \"${PARTICIPANT_DID}\",
  \"protocol\": \"dataspace-protocol-http\"
}" | jq .
```

Asking yourself for your own catalogue is a genuine end-to-end test: it goes out
over DSP and comes back in, exercising the STS, the credential service and the
DSP endpoint.

---

## Phase 9 — First negotiation and transfer  **[YOU]**

Now as a consumer, against a peer. You need their DSP URL and their DID.

**1. Fetch their catalogue.**

```bash
curl -X POST "${MGMT}/v3/catalog/request" "${AUTH[@]}" -d '{
  "@context": { "@vocab": "https://w3id.org/edc/v0.0.1/ns/" },
  "counterPartyAddress": "https://connector.partner.example/partner/cp/dsp",
  "counterPartyId": "did:web:connector.partner.example:partner:ih:did",
  "protocol": "dataspace-protocol-http"
}' | jq .
```

From the response take the dataset you want, its asset id, and the **policy
offer** — you need the offer's `@id` verbatim.

**2. Negotiate.** `assigner` is the provider's participant id (their DID);
`target` is the asset id.

```bash
curl -X POST "${MGMT}/v3/contractnegotiations" "${AUTH[@]}" -d '{
  "@context": { "@vocab": "https://w3id.org/edc/v0.0.1/ns/", "odrl": "http://www.w3.org/ns/odrl/2/" },
  "counterPartyAddress": "https://connector.partner.example/partner/cp/dsp",
  "counterPartyId": "did:web:connector.partner.example:partner:ih:did",
  "protocol": "dataspace-protocol-http",
  "policy": {
    "@type": "odrl:Offer",
    "@id": "<offer id from the catalogue, verbatim>",
    "assigner": "did:web:connector.partner.example:partner:ih:did",
    "target": "<asset id>"
  }
}'
```

**3. Poll until it finalises**, then take the agreement id:

```bash
curl -s "${MGMT}/v3/contractnegotiations/<negotiation id>" "${AUTH[@]}" | jq '.state, .contractAgreementId'
```

`FINALIZED` with a `contractAgreementId` is the moment you have completed a
contract negotiation. Everything before this phase was setup.

**4. Start a transfer.**

```bash
curl -X POST "${MGMT}/v3/transferprocesses" "${AUTH[@]}" -d '{
  "@context": { "@vocab": "https://w3id.org/edc/v0.0.1/ns/" },
  "counterPartyAddress": "https://connector.partner.example/partner/cp/dsp",
  "contractId": "<agreement id>",
  "protocol": "dataspace-protocol-http",
  "transferType": "HttpData-PULL"
}'
```

**5. Read the data.** This connector carries an EONA-X-specific convenience: the
data-plane's **consumer gateway** on `/api/data`. Present the **contract
agreement id** as the `Authorization` header — verbatim, with no `Bearer`
prefix. The gateway looks up the newest matching EDR, resolves its
authorization code and proxies your request out to the provider, forwarding the
path, query string, method and body:

```bash
curl -H "Authorization: <agreement id>" \
     "http://127.0.0.1:28282/api/data/some/path?q=1"
```

If that answers **"No EDR satisfying criterion"**, either the transfer has not
reached a state where an EDR exists yet, or your data-plane is reading a
different database from the one your control-plane wrote the EDR into. The
second is a deployment error: all three runtimes share one database.

The standard EDC route — reading the EDR from the management API and calling the
provider's public endpoint yourself — also works, and is worth knowing for
debugging.

---

## Verification checklist

| Claim | How you know |
| --- | --- |
| The runtimes are up | `scripts/smoke-test.sh` / `helm test` |
| Identity plumbing is sound | the STS issued a token (last smoke-test check) |
| The data-plane is usable | it appears in `GET /v3/dataplanes` |
| Counterparties can find you | your DID document resolves **from outside** |
| You are a member of the dataspace | a `MembershipCredential` from the authority is stored in your hub |
| You can consume | a negotiation reaches `FINALIZED` and a transfer returns data |
| You can provide | a peer negotiates against your catalogue and pulls data |

## Where this typically stalls

| Symptom | Usually |
| --- | --- |
| Credential request returns but nothing is stored | phase 5 was not completed, or your DID does not resolve from the authority's network |
| Unknown credential definition | wrong definition id, or the definitions do not exist in that environment (EONA-X) |
| Control-plane will not start after phase 7 | a malformed trusted-issuer entry, or the authority DID is wrong |
| Catalogue request to a peer returns empty | their policy requires a credential you do not hold yet, or they have not added your DID to their trusted issuers |
| Negotiation stalls in `REQUESTED` | the peer cannot resolve your DID, or cannot reach your credential service |
| Transfer starts but no data | the EDR exists but your data-plane public base URL is not reachable by the provider, or `/api/data` is pointed at a different database |

Nearly all of these are identity failures presented as something else. When a
negotiation stalls, check DID resolution and credentials before you look at
policy.
