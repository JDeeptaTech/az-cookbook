``` bash
TOKEN=$(oc whoami -t)
API=$(oc whoami --show-server)

# Get all VMs, filter client-side (fieldSelector doesn't support spec fields on CRDs)
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$API/apis/kubevirt.io/v1/virtualmachines" | \
  jq '.items[] | select(.spec.template.spec.affinity != null) | {
    name: .metadata.name,
    ns:   .metadata.namespace,
    nodeAffinity:    .spec.template.spec.affinity.nodeAffinity,
    podAffinity:     .spec.template.spec.affinity.podAffinity,
    podAntiAffinity: .spec.template.spec.affinity.podAntiAffinity
  }'


Affinity/anti-affinity rules live in two places:

Pod affinity — inside spec.template.spec.affinity of the VirtualMachine manifest (same structure as Pod affinity, applied to the virt-launcher pod)
VM affinity via KubeVirt-specific CRDs — VirtualMachineAffinityRule doesn't exist as a standalone resource; instead OpenShift Virtualization uses standard Kubernetes node/pod affinity + VirtualMachineInstancePreset (deprecated) or scheduling constraints

So you're querying the VirtualMachine CRD itself and extracting affinity blocks. Here's the full breakdown:

1. CLI
bash# Check if a VM has any affinity defined
kubectl get vm <vm-name> -n <ns> \
  -o jsonpath='{.spec.template.spec.affinity}'

# List all VMs across cluster that have affinity set (non-empty affinity field)
kubectl get vm -A -o json | \
  jq '.items[] | select(.spec.template.spec.affinity != null) | {
    name: .metadata.name,
    namespace: .metadata.namespace,
    affinity: .spec.template.spec.affinity
  }'

# Specifically VMs with podAffinity
kubectl get vm -A -o json | \
  jq '[.items[] | select(.spec.template.spec.affinity.podAffinity != null) | 
    {name:.metadata.name, ns:.metadata.namespace}]'

# Anti-affinity
kubectl get vm -A -o json | \
  jq '[.items[] | select(.spec.template.spec.affinity.podAntiAffinity != null) | 
    {name:.metadata.name, ns:.metadata.namespace}]'

# Node affinity
kubectl get vm -A -o json | \
  jq '[.items[] | select(.spec.template.spec.affinity.nodeAffinity != null) | 
    {name:.metadata.name, ns:.metadata.namespace}]'

2. REST API
bashTOKEN=$(oc whoami -t)
API=$(oc whoami --show-server)

# Get all VMs, filter client-side (fieldSelector doesn't support spec fields on CRDs)
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$API/apis/kubevirt.io/v1/virtualmachines" | \
  jq '.items[] | select(.spec.template.spec.affinity != null) | {
    name: .metadata.name,
    ns:   .metadata.namespace,
    nodeAffinity:    .spec.template.spec.affinity.nodeAffinity,
    podAffinity:     .spec.template.spec.affinity.podAffinity,
    podAntiAffinity: .spec.template.spec.affinity.podAntiAffinity
  }'

3. Python — full inventory
pythonfrom kubernetes import client, config
from dataclasses import dataclass, field
from typing import Optional
import json

config.load_kube_config()
custom = client.CustomObjectsApi()

@dataclass
class VMAffinityInfo:
    name: str
    namespace: str
    node_affinity: Optional[dict]       = None
    pod_affinity: Optional[dict]        = None
    pod_anti_affinity: Optional[dict]   = None
    topology_spread: Optional[list]     = None  # topologySpreadConstraints
    node_selector: Optional[dict]       = None
    tolerations: Optional[list]         = None

    @property
    def has_any_affinity(self) -> bool:
        return any([
            self.node_affinity,
            self.pod_affinity,
            self.pod_anti_affinity,
            self.topology_spread,
        ])


def get_vm_affinity_inventory(namespace: str = None) -> list[VMAffinityInfo]:
    if namespace:
        result = custom.list_namespaced_custom_object(
            "kubevirt.io", "v1", namespace, "virtualmachines"
        )
    else:
        result = custom.list_cluster_custom_object(
            "kubevirt.io", "v1", "virtualmachines"
        )

    inventory = []
    for vm in result.get("items", []):
        spec = vm.get("spec", {}).get("template", {}).get("spec", {})
        affinity = spec.get("affinity", {}) or {}

        info = VMAffinityInfo(
            name             = vm["metadata"]["name"],
            namespace        = vm["metadata"]["namespace"],
            node_affinity    = affinity.get("nodeAffinity"),
            pod_affinity     = affinity.get("podAffinity"),
            pod_anti_affinity= affinity.get("podAntiAffinity"),
            topology_spread  = spec.get("topologySpreadConstraints"),
            node_selector    = spec.get("nodeSelector"),
            tolerations      = spec.get("tolerations"),
        )
        inventory.append(info)

    return inventory


def summarise(inventory: list[VMAffinityInfo]):
    """Print a readable breakdown."""
    vms_with_affinity = [v for v in inventory if v.has_any_affinity]

    print(f"Total VMs: {len(inventory)}")
    print(f"VMs with affinity rules: {len(vms_with_affinity)}\n")

    for vm in vms_with_affinity:
        print(f"{'='*60}")
        print(f"VM: {vm.namespace}/{vm.name}")

        if vm.node_affinity:
            req = vm.node_affinity.get("requiredDuringSchedulingIgnoredDuringExecution", {})
            pref = vm.node_affinity.get("preferredDuringSchedulingIgnoredDuringExecution", [])
            print(f"  nodeAffinity:")
            if req:
                for term in req.get("nodeSelectorTerms", []):
                    for expr in term.get("matchExpressions", []):
                        print(f"    [REQUIRED] node label {expr['key']} {expr['operator']} {expr.get('values', [])}")
            for p in pref:
                for expr in p.get("preference", {}).get("matchExpressions", []):
                    print(f"    [PREFERRED weight={p['weight']}] node label {expr['key']} {expr['operator']} {expr.get('values', [])}")

        if vm.pod_affinity:
            rules = vm.pod_affinity.get("requiredDuringSchedulingIgnoredDuringExecution", [])
            for r in rules:
                sel = r.get("labelSelector", {}).get("matchLabels", {})
                topo = r.get("topologyKey", "")
                print(f"  podAffinity [REQUIRED]: co-locate with pods matching {sel} on topology={topo}")

        if vm.pod_anti_affinity:
            rules = vm.pod_anti_affinity.get("requiredDuringSchedulingIgnoredDuringExecution", [])
            pref_rules = vm.pod_anti_affinity.get("preferredDuringSchedulingIgnoredDuringExecution", [])
            for r in rules:
                sel = r.get("labelSelector", {}).get("matchLabels", {})
                topo = r.get("topologyKey", "")
                print(f"  podAntiAffinity [REQUIRED]: avoid pods matching {sel} on topology={topo}")
            for r in pref_rules:
                term = r.get("podAffinityTerm", {})
                sel = term.get("labelSelector", {}).get("matchLabels", {})
                print(f"  podAntiAffinity [PREFERRED weight={r['weight']}]: avoid pods matching {sel}")

        if vm.topology_spread:
            for t in vm.topology_spread:
                print(f"  topologySpread: maxSkew={t['maxSkew']} key={t['topologyKey']} policy={t['whenUnsatisfiable']}")


if __name__ == "__main__":
    inventory = get_vm_affinity_inventory()
    summarise(inventory)

4. Extract unique affinity rules across the cluster
Useful if you want to audit what rules exist rather than per-VM:
pythonfrom collections import defaultdict

def extract_unique_affinity_rules(inventory: list[VMAffinityInfo]) -> dict:
    """
    Returns a deduplicated map of all affinity rules in use cluster-wide.
    Groups by rule type and topology key so you can see patterns.
    """
    rules = defaultdict(list)

    for vm in inventory:
        ref = f"{vm.namespace}/{vm.name}"

        if vm.node_affinity:
            req = vm.node_affinity.get("requiredDuringSchedulingIgnoredDuringExecution", {})
            for term in req.get("nodeSelectorTerms", []):
                for expr in term.get("matchExpressions", []):
                    key = f"nodeAffinity::required::{expr['key']}::{expr['operator']}::{tuple(sorted(expr.get('values', [])))}"
                    rules[key].append(ref)

        if vm.pod_anti_affinity:
            for r in vm.pod_anti_affinity.get("requiredDuringSchedulingIgnoredDuringExecution", []):
                sel = r.get("labelSelector", {}).get("matchLabels", {})
                key = f"podAntiAffinity::required::{r.get('topologyKey')}::{sel}"
                rules[key].append(ref)

            for r in vm.pod_anti_affinity.get("preferredDuringSchedulingIgnoredDuringExecution", []):
                term = r.get("podAffinityTerm", {})
                sel = term.get("labelSelector", {}).get("matchLabels", {})
                key = f"podAntiAffinity::preferred::{term.get('topologyKey')}::{sel}"
                rules[key].append(ref)

        if vm.pod_affinity:
            for r in vm.pod_affinity.get("requiredDuringSchedulingIgnoredDuringExecution", []):
                sel = r.get("labelSelector", {}).get("matchLabels", {})
                key = f"podAffinity::required::{r.get('topologyKey')}::{sel}"
                rules[key].append(ref)

    return dict(rules)

# Usage:
inventory = get_vm_affinity_inventory()
rules = extract_unique_affinity_rules(inventory)
for rule, vms in rules.items():
    print(f"\nRule: {rule}")
    print(f"  Applied to: {vms}")

5. One important thing about how VM affinity actually works
The affinity in the VirtualMachine spec applies to the virt-launcher pod, not directly to a VM-level scheduler. This means:
VirtualMachine.spec.template.spec.affinity
        ↓ (KubeVirt copies this to)
virt-launcher Pod.spec.affinity
        ↓ (Kubernetes scheduler uses this)
Node placement decision
So if you also want to verify the affinity is being honoured at runtime, check the live virt-launcher pods:
bash# Cross-check: affinity on the actual launcher pod for a running VM
kubectl get pod -n <ns> -l kubevirt.io/vm=<vm-name> \
  -o jsonpath='{.items[0].spec.affinity}'

# Or via Python:
v1 = client.CoreV1Api()
pods = v1.list_namespaced_pod(
    namespace="my-ns",
    label_selector="kubevirt.io/vm=my-vm"
)
for pod in pods.items:
    print(pod.spec.affinity)
This matters for debugging scheduling failures — the VM object might look correct but the launcher pod spec is what the scheduler actually reads.
```
