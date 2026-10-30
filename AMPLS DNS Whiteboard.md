# AMPLS + DNS Private Resolver — *central privatelink DNS*

Hub-and-spoke target state, who owns what in each subscription, how a lookup flows, and how the privatelink zones move off the enterprise DNS servers wave by wave.

On-premises / DNS servers Network (connectivity) sub Shared prod (management) sub Workload subs Lookup path ①–⑤

## ① Target architecture one resolver · one set of zones · one AMPLS

## ② Migration flow zones leave the DNS servers one wave at a time

**One AMPLS per DNS**AMPLS endpoints like `api.monitor.azure.com` are global. A second AMPLS + PE on networks sharing this resolver overwrites the first one's records.

**Blob moves with AMPLS**The AMPLS PE writes into `privatelink.blob.core.windows.net`. Leave that zone on-prem and agents lose solution-pack downloads.

**Forward public, not privatelink**Forwarder = `blob.core.windows.net`, then delete the local `privatelink.*` zone. A leftover local zone is more specific and wins.

**No Azure zones outbound**The resolver ruleset forwards only on-prem names. Add `blob.core.windows.net` there and you build a loop with on-prem.

**Open first, PrivateOnly last**PrivateOnly blocks every network on this DNS from any workspace not in the AMPLS, in any subscription or tenant.

**NewPrivatePath rows**PEs with no on-prem record today resolve public. After cutover they go private, so check ER routes and NSGs first.