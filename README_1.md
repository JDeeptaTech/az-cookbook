# ansible-eos-kubeconfig-generator

Tactical replacement for the htpasswd breakglass accounts, until Delinea is ready (Q1 2027).
An operator runs a playbook, picks a cluster and an account, and gets a **personal kubeconfig
that works for at most 4 hours**. The client certificate is requested through cert-manager on the
ACM hub and **signed by Vault PKI**, where the limits are enforced.

```
 operator ──► generate_kubeconfig.yml (AAP / CLI)
                │ 1. hub token from Vault KV
                │ 2. private key + CSR generated locally; the key never leaves the controller
                ▼
        ACM hub  eos-breakglass ns ── CertificateRequest ──► Issuer eos-breakglass-<cluster> (namespaced)
                                                                │ cert-manager logs in to Vault as SA
                                                                │ eos-breakglass-vault-signer (k8s auth)
                                                                ▼
                                      Vault  pki-eos-breakglass-<cluster>/sign/breakglass-client
                                             ≤ 4h · CN eos-breakglass:* · O forced · EC P-256 · clientAuth only
                │ 3. signed certificate back
                ▼
         kubeconfig = cluster API + CA + client cert + key
                │ 4. checked against the cluster (SelfSubjectReview)
                ▼
         ~/.kube/breakglass/<cluster>-<account>-<person>.kubeconfig  (0600)
                │
                ▼
         oc --kubeconfig <file> ...        (no oc login)

 bootstrap_cluster.yml (once per cluster, and whenever the user list changes)
        reads the cluster's CA from Vault, creates the hub Issuer, then
        ACM hub ── ManifestWork ──► managed cluster:
                     ConfigMap openshift-config/eos-breakglass-client-ca   (trusted client CAs)
                     APIServer/cluster spec.clientCA                        (server-side apply, owns only that field)
                     ClusterRoleBinding per account, subjects = named people only
```

What other teams must set up first, with ready-to-apply files and the request text for each
owner, is in [`admin-request/`](admin-request/README.md).

## What changed from the Confluence design, and why

| Confluence step | Here | Why |
|---|---|---|
| Get breakglass SA token from Hashi for the ACM cluster | Same: two hub service accounts, tokens in Vault KV | Split into an **issuer** SA (can only create CertificateRequests in one namespace) and an **admin** SA (bootstrap). Neither can read Secrets. |
| Request a certificate from ACM cert-manager | Same, but as a **CSR** (`CertificateRequest`), and **signed by Vault PKI** | With a `Certificate`, cert-manager generates the key and stores it in a Secret on the hub; with a CSR the key exists only in the kubeconfig. Vault signs because the Red Hat cert-manager operator can't turn off the built-in approver, so the hub can't enforce limits itself (see `admin-request/README.md`). |
| *(not in the design)* | **One Vault PKI mount (CA) per managed cluster** | With a single CA, a certificate issued "for cluster A" works on every cluster. |
| *(not in the design)* | **Bootstrap each cluster to trust its CA** | OpenShift only accepts client certs from CAs in `apiserver/cluster spec.clientCA`. Pushed from the hub by ManifestWork. |
| Package into a kubeconfig | Same layout as the sample: `client-certificate-data` / `client-key-data` | Adds expiry, ticket and fingerprint as comments, and checks the result against the cluster before writing it. |
| Hand over on the bastion or by email | **The playbook only writes the file** (0600, in a 0700 directory) | No email: it would leave a cluster credential in mailboxes and backups. Run it where the person works. |

## Security properties (each one tested, see *Testing*)

**Maximum 4 hours, enforced where it can't be bypassed**
1. The playbook refuses anything over `breakglass_max_duration_hours` (4).
2. The Vault role has `max_ttl=4h`. A request for 5h or 90 days made directly on the hub, without the playbook, still comes back as a 4h certificate. This is the control that matters.
3. The playbook checks the signed certificate's validity before writing the file.

**Valid only for the person it was issued to**
- The user name is `eos-breakglass:<account>:<person>`. Changing the user name in the kubeconfig changes nothing. Editing the name inside the certificate breaks the signature.
- The group (O) is set by Vault to `eos-breakglass`, whatever the CSR asks for, so `O=system:masters` is impossible. Vault also refuses any CN outside `eos-breakglass:*` (e.g. `kube-admin`, hostnames) and any non-EC key.
- RBAC on each cluster binds **named people only** (`User` subjects), never the group. A certificate minted for anyone not on `allowed_operators` authenticates but can do nothing.
- Only the person asking can be the recipient, unless `breakglass_allow_delegation` is set.
- The private key is generated per issuance. Mixing certificates and keys fails the TLS handshake.

**Who can get anything signed**
- The Issuer is **namespaced** in `eos-breakglass`. A CertificateRequest from any other hub namespace can't reference it.
- Only the issuer SA (and hub cluster-admins) can create CertificateRequests there.
- Only cert-manager can mint a token for `eos-breakglass-vault-signer`. Vault accepts that token only for this SA, namespace and audience `vault://eos-breakglass/eos-breakglass-<cluster>`, and only for that cluster's signing path.
- Bootstrap only reaches clusters whose hub namespace was explicitly onboarded (`admin-request/hub/04`).

**Tampering fails.** The cluster rejects all of these:
- the name edited inside the certificate;
- someone else's certificate used with your key;
- a self-made certificate carrying a real user's and the CA's name;
- a certificate for another cluster;
- an expired certificate, or one that is not yet valid (signed with the real CA key, in the test).

**Revocation.** Kubernetes checks no CRL or OCSP. Instead:
- **One person:** remove them from `allowed_operators` and re-run bootstrap. Their live certificates stop working at once.
- **Everyone on a cluster:** `-e breakglass_enabled=false`. All bindings are removed; the CA trust and `clientCA` are kept, so re-enabling causes no rollout.
- **Worst case:** the certificate expires within 4 hours.

**Audit.** Every issuance is a CertificateRequest on the hub, labelled with cluster, account and operator, and annotated with ticket, reason, recipient, certificate fingerprint and expiry. Vault's audit device logs every signing. On the cluster, every API call is logged under the person's name.

## Points for Cyber / Crypto review

1. **Hub cluster-admins can still request certificates (tested).** They can create a CertificateRequest in `eos-breakglass`, and Vault signs anything within the role's limits. They can get a 4h certificate in a real operator's name, and it works where that name is bound. It is attributable in the hub audit log and the Vault audit log. Mitigations:
   - keep hub cluster-admin minimal;
   - alert on `create certificaterequests` in `eos-breakglass` by anyone other than the issuer SA.
   The CA key is no longer on the hub, so offline minting is not possible.
2. **Who holds the issuer token.** Anyone who can read it from Vault can do what point 1 describes. The "only the person asking" rule is enforced by the playbook. Run it from AAP, so only AAP holds the Vault credential.
3. **No revocation, by design.** Covered by the 4h cap and RBAC removal. Confirm 4h is acceptable for incident use.
4. **Algorithms.** Client keys ECDSA P-256 (enforced by Vault), per-cluster roots ECDSA P-384, 5 years. Bootstrap keeps every unexpired CA it has seen in the trust bundle, so rotating a root in Vault doesn't break live certificates. Re-run bootstrap after a rotation.
5. **Breakglass depends on the hub and Vault.** If either is down, nothing can be issued. Keep the installer `kubeconfig` (`system:admin`) sealed in Vault as the last resort, and test opening it.
6. **First rollout.** The first time `spec.clientCA` is set, the kube-apiserver operator rolls out a new revision (about 10–20 minutes, no node reboot). If `clientCA` is already owned by something else, the ManifestWork fails rather than replacing it (`force: false`).
7. **Deleting the ManifestWork is safe.** The APIServer config and CA ConfigMap are orphaned, never deleted.

## Prerequisites

- **Other teams:** everything in [`admin-request/`](admin-request/README.md) — hub namespaces/SAs/RBAC, Vault Kubernetes auth, per-cluster Vault PKI, onboarding per cluster. The cert-manager install needs no change.
- **Controller / AAP execution environment:**
  - Collections: `ansible-galaxy collection install -r requirements.yml`
  - Python libraries: `pip install -r requirements.txt`
  - Vault auth through `VAULT_ADDR` and `VAULT_TOKEN`, or AppRole.
- **Config:** `playbooks/group_vars/all/main.yml` holds the hub URL, Vault paths and PKI names, the account catalogue with `allowed_operators`, and the output directory (default `~/.kube/breakglass`). It sits next to the playbooks, so it applies with AAP inventories too. Set `vault_server_for_cert_manager` if cert-manager reaches Vault on a different URL, and `vault_ca_cert_path` if Vault's TLS CA is private.

## Use

```bash
# once per managed cluster (and after changing allowed_operators)
ansible-playbook playbooks/bootstrap_cluster.yml -e target_cluster=ocp-prod-01

# issue a kubeconfig (prompts for anything not given)
ansible-playbook playbooks/generate_kubeconfig.yml \
  -e target_cluster=ocp-prod-01 -e breakglass_account=eos-cluster-admin \
  -e breakglass_duration_hours=2 -e breakglass_ticket=INC0012345 \
  -e "breakglass_reason='OAuth outage, need to restore identity provider'"

# switch breakglass off for a cluster (live certificates stop working immediately)
ansible-playbook playbooks/bootstrap_cluster.yml -e target_cluster=ocp-prod-01 -e breakglass_enabled=false
```

The playbook writes `~/.kube/breakglass/<cluster>-<account>-<person>.kubeconfig` and stops. Use it directly with `oc`; the certificate is the login.

```bash
oc --kubeconfig ~/.kube/breakglass/ocp-prod-01-eos-cluster-admin-alice.smith.kubeconfig whoami
# eos-breakglass:eos-cluster-admin:alice.smith

export KUBECONFIG=~/.kube/breakglass/ocp-prod-01-eos-cluster-admin-alice.smith.kubeconfig
oc get nodes

rm ~/.kube/breakglass/ocp-prod-01-eos-cluster-admin-alice.smith.kubeconfig   # when finished
```

- **Don't run `oc login` with this file.** It starts an OAuth login and writes a token into the kubeconfig.
- **After expiry,** `oc` fails with `error: You must be logged in to the server (Unauthorized)`. Run the playbook again.
- **In AAP:** make `target_cluster`, `breakglass_account`, `breakglass_duration_hours` (max 4), `breakglass_ticket` and `breakglass_reason` survey questions. AAP's `awx_user_name` becomes the person on the certificate. Set `breakglass_output_dir` to somewhere the person can reach, since the execution environment is discarded.

## Testing

`tests/e2e` is a local rig that needs no OpenShift and no container runtime:
- **Real:** three Kubernetes 1.31 API servers (an ACM hub and two managed clusters) with real RBAC, TokenRequest/TokenReview and audit logging, plus the real cert-manager, OCM and OpenShift `APIServer` CRDs. The `admin-request/hub` YAML and `admin-request/vault` scripts are applied unchanged.
- **Stand-ins** (`fakes.py`) for:
  - the cert-manager controller, with the built-in approver on and a Vault issuer using Kubernetes auth;
  - Vault: KV, policies, Kubernetes auth with a real TokenReview against the hub, and PKI `sign` with the role rules the scripts set;
  - the klusterlet work agent (server-side apply);
  - OpenShift's kube-apiserver operator.

```bash
export ENVTEST_BIN=/path/to/envtest-v1.31.0/bin   # etcd, kube-apiserver, kubectl
tests/e2e/start-env.sh && tests/e2e/run.sh
```

`run.sh` runs **40 checks**: the legitimate path, tampering, the 4h cap (through the playbook and directly on the hub), Vault's role rules, who on the hub can request or sign, per-person binding, onboarding boundaries, revocation, secret handling, and using the file via `--kubeconfig` and `KUBECONFIG`. All pass. kubectl stands in for `oc`; it loads kubeconfig files the same way.

**Not covered by the rig, so check in the lab POC:**
- **a real Vault.** The PKI role behaviour is emulated from Vault's documentation (`cn_validations`, glob `allowed_domains`, `organization`, `max_ttl` capping). `admin-request/README.md` → *Verify* has the commands to confirm it;
- the real cert-manager Vault issuer and the Red Hat operator's SA name;
- the real kube-apiserver operator rollout and klusterlet;
- AAP surveys and the real `oc` binary.
