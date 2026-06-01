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
```
