# ansible-eos-kubeconfig-generator

Tactical replacement for the htpasswd breakglass accounts, until Delinea is ready (Q1 2027).
An operator runs a playbook, picks a cluster and an account, and gets a **personal kubeconfig
that works for at most 4 hours**, backed by a client certificate from cert-manager on the ACM hub.

```
 operator ──► generate_kubeconfig.yml (AAP / CLI)
                │ 1. hub token from Vault (KV v2)
                │ 2. private key + CSR generated locally; the key never leaves the controller
                ▼
        ACM hub ── cert-manager CertificateRequest ──► approver-policy (≤ 4h, eos-breakglass:* only)
                │                                      └─► ClusterIssuer eos-breakglass-<cluster> (CA per cluster)
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
        ACM hub ── ManifestWork ──► managed cluster:
                     ConfigMap openshift-config/eos-breakglass-client-ca   (trusted client CAs)
                     APIServer/cluster spec.clientCA                        (server-side apply, owns only that field)
                     ClusterRoleBinding per account, subjects = named people only
```

## What changed from the Confluence design, and why

| Confluence step | Here | Why |
|---|---|---|
| Get breakglass SA token from Hashi for the ACM cluster | Same: two hub service accounts, tokens in Vault | Split into an **issuer** SA (can only create CertificateRequests) and an **admin** SA (bootstrap). Neither can read Secrets, so the CA keys stay with cert-manager. |
| Request a certificate from ACM cert-manager | Same, but as a **CSR** (`CertificateRequest`), not a `Certificate` | With a `Certificate`, cert-manager generates the key and stores it in a Secret on the hub. With a CSR, the key is created on the controller and exists only in the kubeconfig file. |
| *(not in the design)* | **One CA per managed cluster** | With a single CA, a certificate issued "for cluster A" works on every cluster. Per-cluster CAs keep a cert to the cluster it was issued for (tested). |
| *(not in the design)* | **Bootstrap each cluster to trust the CA** | OpenShift only accepts client certs from CAs listed in `apiserver/cluster spec.clientCA`. Without this step no cert-manager certificate authenticates. It is pushed from the hub by ManifestWork. |
| Package into a kubeconfig | Same layout as the sample: `client-certificate-data` / `client-key-data` | Adds expiry, ticket and fingerprint as comments, and checks the result against the cluster before handing it over. |
| Hand over on the bastion or by email | **The playbook only writes the file** (0600, in a 0700 directory). The person uses it with `oc --kubeconfig` | No email: it would leave a cluster credential in mailboxes, journaling and backups. Run the playbook where the person works (the bastion), so the file is already theirs. |

## Security properties (each one tested, see *Testing*)

**Maximum 4 hours, enforced three times**
1. The playbook refuses anything over `breakglass_max_duration_hours` (4).
2. cert-manager approver-policy on the hub denies any CertificateRequest over 4h, including requests made directly on the hub without the playbook. This is the control that matters.
3. The playbook checks the signed certificate's validity before writing the file.

**Valid only for the person it was issued to**
- The certificate's user name is `eos-breakglass:<account>:<person>`. Changing the user name in the kubeconfig changes nothing. Editing the name inside the certificate breaks its signature, and the cluster rejects it.
- RBAC on each cluster binds **named people only**, not a group. A certificate minted for anyone not on `allowed_operators` authenticates but can do nothing.
- Only the person asking can be the recipient, unless `breakglass_allow_delegation` is set.
- The private key is generated per issuance and never sent anywhere except inside the kubeconfig. Using someone else's certificate needs their key; mixing certs and keys fails the TLS handshake.

**Tampering fails.** The cluster rejects all of these:
- the name edited inside the certificate;
- someone else's certificate used with your key;
- a self-made certificate carrying a real user's name;
- a certificate for another cluster;
- an expired certificate, or one that is not yet valid;
- a request for `system:masters` (denied by policy).

**Revocation.** Kubernetes cannot revoke a client certificate: it checks no CRL or OCSP. Instead:
- **One person:** remove them from `allowed_operators` and re-run bootstrap. Their live certificates stop working at once (tested).
- **Everyone on a cluster:** `-e breakglass_enabled=false`. All bindings are removed, and the CA trust and the `clientCA` setting are kept.
- **Worst case:** the certificate expires within 4 hours.

**Audit.** Every issuance is a CertificateRequest on the hub, labelled with cluster, account and operator, and annotated with ticket, reason, recipient, certificate fingerprint and expiry. On the cluster, every API call is logged under the person's name.

## Points for Cyber / Crypto review

1. **Hub cluster-admins can mint breakglass certificates (tested).** `system:masters` on the hub passes the approver-policy `use` check. A hub cluster-admin could therefore issue a certificate in a real operator's name, and it would work on a managed cluster. It is attributable: the hub audit log records the real requester. Mitigations:
   - keep hub cluster-admin membership minimal;
   - alert on any `create certificaterequests` in `eos-breakglass` by anyone other than `system:serviceaccount:eos-automation:eos-breakglass-issuer` (the hub audit policy must log that resource at Metadata level);
   - **recommended:** use a Vault PKI issuer instead of the CA issuer. The signing key and its role constraints (TTL ≤ 4h, allowed CNs) then live in Vault, outside the hub's trust boundary.
2. **The CA private keys are Secrets in `cert-manager` on the hub** (CA issuer mode). Anyone who can read them can mint certificates offline. Mitigations: restrict Secret access in that namespace, enable etcd encryption, or use the Vault PKI issuer (point 1).
3. **No revocation, by design.** Covered by the 4h cap and RBAC removal above. Confirm the 4h figure is acceptable for incident use.
4. **Algorithms.** Client keys are ECDSA P-256 and per-cluster CAs are ECDSA P-384, both signed with SHA-384. The CAs are valid for 5 years and renew 1 year before expiry. Bootstrap keeps the previous CA in the trust bundle until it expires, so a renewal doesn't break live certificates.
5. **Who holds the issuer token.** If each person runs the playbook themselves (for example on the bastion), each of them can read the issuer service-account token from Vault. With it they could bypass the playbook and request a certificate in a colleague's name. The approver policy still holds the 4h cap and the `eos-breakglass:*` shape, and the request is recorded on the hub, but the "only the person asking" rule is enforced only by the playbook in that model. To close this, run the playbook from AAP, so only AAP holds the Vault credential, and have the job write the file where the person can collect it.
6. **Breakglass depends on the hub.** If the ACM hub or Vault is down, nothing can be issued. Keep the installer `kubeconfig` (`system:admin`) sealed in Vault as the last resort, and test opening it.
7. **First rollout.** The first time `spec.clientCA` is set, the kube-apiserver operator rolls out a new revision (about 10–20 minutes, no node reboot). If a cluster already has a `clientCA` owned by something else, the ManifestWork fails rather than replacing it (`force: false`). Merge the bundles by hand in that case.
8. **Deleting the ManifestWork is safe.** The APIServer config and the CA ConfigMap are orphaned, never deleted, so the cluster is never left pointing at a missing ConfigMap.

## Prerequisites

- **ACM hub:** cert-manager (the cert-manager Operator for Red Hat OpenShift) and **cert-manager approver-policy**, with cert-manager's built-in approver disabled (`--controllers=*,-certificaterequests-approver`). Otherwise any CertificateRequest is auto-approved.
- **Hub setup, once:** `oc apply -f hub-rbac/hub-setup.yaml`. This creates the namespaces, the two service accounts, least-privilege RBAC, the root issuer and the approver policies.
- **Vault (KV v2):** store each service account's token, under key `token`:
  - `secret/eos/acm-hub/sa/eos-breakglass-issuer`
  - `secret/eos/acm-hub/sa/eos-breakglass-admin`
- **Controller / AAP execution environment:**
  - Collections: `ansible-galaxy collection install -r requirements.yml`
  - Python libraries: `pip install -r requirements.txt`
  - Vault auth through `VAULT_ADDR` and `VAULT_TOKEN`, or AppRole.
- **Config:** `playbooks/group_vars/all/main.yml` holds the hub URL, Vault paths, the account catalogue with `allowed_operators`, and the output directory (default `~/.kube/breakglass`). It sits next to the playbooks, so it applies with AAP inventories too.

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

The playbook writes `~/.kube/breakglass/<cluster>-<account>-<person>.kubeconfig` and stops. Use it directly with `oc`. There is no `oc login` step: the certificate is the login.

```bash
oc --kubeconfig ~/.kube/breakglass/ocp-prod-01-eos-cluster-admin-alice.smith.kubeconfig whoami
# eos-breakglass:eos-cluster-admin:alice.smith

export KUBECONFIG=~/.kube/breakglass/ocp-prod-01-eos-cluster-admin-alice.smith.kubeconfig
oc get nodes
oc adm top nodes

rm ~/.kube/breakglass/ocp-prod-01-eos-cluster-admin-alice.smith.kubeconfig   # when finished
```

- **Don't run `oc login` with this file.** It starts an OAuth login and writes a token into the kubeconfig, which defeats the point. The current context is already set.
- **After expiry,** `oc` fails with `error: You must be logged in to the server (Unauthorized)`. Run the playbook again.
- **To choose where the file goes,** pass `-e breakglass_output_dir=/some/dir`.

**In AAP:** make `target_cluster`, `breakglass_account`, `breakglass_duration_hours` (max 4), `breakglass_ticket` and `breakglass_reason` survey questions. AAP passes `awx_user_name`, which becomes the person on the certificate. The file is written inside the job's execution environment and disappears with it, so for AAP set `breakglass_output_dir` to a location the person can reach. See review point 5 for why AAP is the safer place to run this.

## Testing

`tests/e2e` is a local rig that needs no OpenShift and no container runtime:
- **Real:** three Kubernetes 1.31 API servers (an ACM hub and two managed clusters), with the real cert-manager, approver-policy, OCM and OpenShift `APIServer` CRDs.
- **Stand-ins** (`fakes.py`) for:
  - cert-manager signing;
  - approver-policy, which identifies the requester from the hub audit log and checks the `use` verb with a SubjectAccessReview;
  - the klusterlet work agent, using server-side apply;
  - OpenShift's kube-apiserver operator, which turns `spec.clientCA` into trusted CAs;
  - Vault.

```bash
export ENVTEST_BIN=/path/to/envtest-v1.31.0/bin   # etcd, kube-apiserver, kubectl
tests/e2e/start-env.sh && tests/e2e/run.sh
```

`run.sh` bootstraps both clusters, issues a kubeconfig, and runs 34 checks: the legitimate path, tampering, the 4h cap (through the playbook and directly on the hub), per-person binding, revocation, secret handling, and using the file via `--kubeconfig` and `KUBECONFIG`. The rig uses kubectl, which loads kubeconfig files the same way `oc` does.

**Not covered by the rig, so check in the lab POC:**
- the real kube-apiserver operator rollout;
- the real cert-manager and approver-policy controllers. The stand-ins follow their documented behaviour, but are not the binaries.
- the real klusterlet;
- an actual CA renewal;
- AAP surveys;
- the real `oc` binary.
