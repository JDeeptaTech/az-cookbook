# Admin request: breakglass kubeconfig (Vault PKI)

Everything the platform needs from other teams before `ansible-eos-kubeconfig-generator` can run.
Each file says who owns it and when to apply it in its header. Nothing here gives the automation
cluster-admin on the hub, read access to Secrets, or any way to sign a certificate itself.

## Order of operations

| # | Owner | What | Files | When |
|---|---|---|---|---|
| 1 | ACM hub admin | Namespaces, service accounts, least-privilege RBAC | `hub/01`, `02`, `03`, `05`, `06` | once |
| 2 | ACM hub admin | Long-lived tokens for the reviewer and the two automation SAs | `hub/06` (reviewer Secret), `hub/07` | once; rotate per policy |
| 3 | Vault team | Kubernetes auth mount trusting the hub | `vault/01-hub-kubernetes-auth.sh` | once |
| 4 | Vault team | KV entries for the two automation tokens + read policies for AAP | `hub/07` commands, `vault/03-automation-policies.hcl` | once |
| 5 | Vault team | Per-cluster PKI mount, signing role, signer policy and auth role | `vault/02-onboard-cluster.sh` | per managed cluster |
| 6 | ACM hub admin | Let the bootstrap SA write ManifestWorks in that cluster's namespace | `hub/04-onboard-cluster-TEMPLATE.yaml` | per managed cluster |
| 7 | Platform (us) | `ansible-playbook playbooks/bootstrap_cluster.yml -e target_cluster=<name>` | — | per managed cluster |
| 8 | Managed cluster owner | Accept a one-off kube-apiserver rollout (see below) | — | first bootstrap |

cert-manager team: **no change needed.** The Red Hat cert-manager Operator stays as installed,
built-in approver included.

## What to send each owner

### ACM hub admin

> Please apply `hub/01`, `02`, `03`, `05`, `06`, `07` on the ACM hub (`oc apply -f`), and for each
> managed cluster we onboard:
> `sed s/CLUSTER_NAME/<cluster>/g hub/04-onboard-cluster-TEMPLATE.yaml | oc apply -f -`.
> Then hand the three tokens to the Vault team directly (commands are in the file headers), not by
> email or chat.
>
> What it grants:
> - `eos-breakglass-issuer` (automation): create/get/patch CertificateRequests and get Issuers,
>   **only in `eos-breakglass`**; get ManagedClusters.
> - `eos-breakglass-admin` (automation): create/patch the per-cluster `Issuer` in `eos-breakglass`;
>   get ManagedClusters; create/patch ManifestWorks **only in namespaces you onboard via hub/04**.
> - `eos-breakglass-vault-signer`: no RBAC at all. It exists so Vault can recognise cert-manager.
> - cert-manager's SA: create a token **for that one SA only** (`resourceNames`), so it can log in to Vault.
> - `vault-token-reviewer`: `system:auth-delegator` (TokenReview), used only by Vault.
>
> Please also (a) keep hub cluster-admin membership minimal, and (b) alert on
> `create certificaterequests` in `eos-breakglass` by anyone other than
> `system:serviceaccount:eos-automation:eos-breakglass-issuer` (needs the hub audit policy to log
> `cert-manager.io/certificaterequests` at Metadata level or above).

### Vault team

> 1. With `HUB_API_URL`, `HUB_CA_FILE` and `REVIEWER_JWT_FILE` (the token from
>    `hub/06`'s Secret) set, run `vault/01-hub-kubernetes-auth.sh`.
> 2. Store the two tokens from `hub/07` at `secret/eos/acm-hub/sa/eos-breakglass-issuer` and
>    `.../eos-breakglass-admin` (key `token`). Create the two policies from
>    `vault/03-automation-policies.hcl` and attach them to the AAP AppRole, **not to people**.
> 3. Per managed cluster: `CLUSTER=<name> vault/02-onboard-cluster.sh`. It creates
>    `pki-eos-breakglass-<cluster>` with an ECDSA P-384 root (5 years) and a `breakglass-client`
>    role that only signs:
>    - client-auth certificates (no server, code-signing or email use);
>    - CN `eos-breakglass:*`, no SANs, ECDSA P-256 keys;
>    - O forced to `eos-breakglass` whatever the CSR says;
>    - **at most 4h** (`max_ttl`), with 30s backdating.
>
>    Only cert-manager's `eos-breakglass-vault-signer` token, with audience
>    `vault://eos-breakglass/eos-breakglass-<cluster>`, can log in to the per-cluster auth role, and
>    its Vault token lives 1–5 minutes.
>
> Please send back: the Vault URL cert-manager should use, and its CA bundle if it is not publicly
> trusted (we set `vault_server_for_cert_manager` / `vault_ca_cert_path`).

**Before go-live, please confirm against your Vault version** (written from the Vault docs; the
test rig emulates Vault rather than running it): that `cn_validations=disabled` +
`allowed_domains="eos-breakglass:*"` + `allow_glob_domains=true` accepts
`eos-breakglass:eos-cluster-admin:alice.smith` and refuses `kube-admin`; that `organization` on
the role replaces the CSR's O; and that a `ttl` of 90 days is capped to 4h rather than refused.
The commands under *Verify* do exactly that.

### Managed cluster owner

> The first bootstrap sets `apiserver/cluster spec.clientCA` to the ConfigMap
> `openshift-config/eos-breakglass-client-ca`. The kube-apiserver operator rolls out a new revision
> (about 10–20 minutes per control-plane node, no reboot, API stays up). If `spec.clientCA` is
> already set by someone else, bootstrap stops instead of overwriting it; we then merge the bundles.
> We also create one ClusterRoleBinding per breakglass account (`eos-breakglass-<account>`) whose
> subjects are named people only. Removing the ManifestWork orphans the CA settings rather than
> deleting them.

## Verify

```bash
# hub: the boundaries hold
oc auth can-i create certificaterequests -n eos-breakglass  --as system:serviceaccount:eos-automation:eos-breakglass-issuer   # yes
oc auth can-i create certificaterequests -n default         --as system:serviceaccount:eos-automation:eos-breakglass-issuer   # no
oc auth can-i get secrets -A                                 --as system:serviceaccount:eos-automation:eos-breakglass-issuer   # no
SIGNER="serviceaccount/eos-breakglass-vault-signer --subresource=token -n eos-breakglass"
oc auth can-i create $SIGNER --as system:serviceaccount:eos-automation:eos-breakglass-issuer   # no
oc auth can-i create $SIGNER --as system:serviceaccount:cert-manager:cert-manager             # yes (that one SA only)
oc auth can-i create manifestworks -n <cluster> --as system:serviceaccount:eos-automation:eos-breakglass-admin                 # yes once hub/04 applied

# Vault: the role signs only what it should (any test CSR; nothing is trusted until bootstrap)
M=pki-eos-breakglass-<cluster>
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout /dev/null \
  -subj "/CN=eos-breakglass:eos-cluster-admin:test/O=system:masters" -out ok.csr
vault write -field=certificate $M/sign/breakglass-client csr=@ok.csr ttl=2160h \
  | openssl x509 -noout -subject -dates -ext extendedKeyUsage
#   expect: O = eos-breakglass, notAfter ≈ now+4h, TLS Web Client Authentication only
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout /dev/null -subj "/CN=kube-admin" -out bad.csr
vault write $M/sign/breakglass-client csr=@bad.csr        # expect: common name kube-admin not allowed

# after bootstrap_cluster.yml: the cluster trusts the CA
oc get apiserver cluster -o jsonpath='{.spec.clientCA.name}'      # eos-breakglass-client-ca
oc get co kube-apiserver                                          # Progressing=False once rolled out
```

## Why Vault PKI, not cert-manager's CA issuer + approver-policy

The first version signed with a cert-manager CA issuer and relied on **approver-policy** to enforce
the 4h cap and the `eos-breakglass:*` name. That only works if cert-manager's built-in approver is
switched off (`--controllers=*,-certificaterequests-approver`). The Red Hat cert-manager Operator does
not allow that: `CertManager.spec.controllerConfig.overrideArgs` takes an allow-list of flags, and
`--controllers` is not on it (checked up to 1.20.1). The only way would be
`unsupportedConfigOverrides`, which Red Hat does not support. With the built-in approver on, every
CertificateRequest is approved, so the hub could not enforce any limit.

With Vault PKI the limits (lifetime, name shape, key type, usages, O) sit in the Vault role,
outside the hub. Approval by the hub becomes irrelevant, and the CA key never exists on the hub.

## Residual risks (for Cyber / Crypto)

- Anyone allowed to create CertificateRequests in `eos-breakglass` (the issuer SA, hub
  cluster-admins) can get a certificate for any `eos-breakglass:*` name, within the role limits.
  It only works on a cluster if that name is bound there, and the request is in the hub audit log.
- Whoever can read the issuer token from Vault has that ability too. Keep it with AAP.
- Breakglass needs the hub and Vault up. Keep the installer kubeconfig sealed as the last resort.
