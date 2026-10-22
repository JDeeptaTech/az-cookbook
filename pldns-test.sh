#!/usr/bin/env bash
# Private Link DNS policy test: one test subscription + private DNS zones in a shared
# subscription, using az CLI only. Builds the SAME initiative as the Terraform stack
# (lib/builtin-private-dns/catalog.json + lib/definitions/network/*.json), assigned at
# subscription scope.
#
# Identities (mirrors production):
#   Deployer SPN       app registration, 1-day client secret (local test only; the
#                      pipeline uses workload identity federation). Runs deploy,
#                      remediate and status from an isolated az profile, which proves
#                      it can work with only its own roles.
#   Remediation UAMI   attached to the assignment; DeployIfNotExists runs as it.
#
# Steps (run in order):
#   infra      human  DNS RG + zones (shared sub), test RG, VNet, VM, storage + pre-existing queue PE
#   identity   human  deployer SPN + secret, remediation UAMI, all RBAC
#   deploy     SPN    custom definitions, initiative, assignment (with the UAMI)
#   deny-test  human  waits until the assignment is live; proves spoke privatelink zones are denied
#   pe         human  creates the test services and their private endpoints (no DNS integration)
#   verify     human  waits for zone groups; checks zone, A record, IP and VM name resolution
#   remediate  SPN    compliance scan + remediation tasks (fixes the pre-existing queue PE)
#   status     SPN    compliance per policy reference and remediation task states
#   rbac-check human  lists every role held by the SPN and the UAMI, flags anything unexpected
#   down       human  removes everything this script created (zones only if PURGE_DNS=true)
#
# Human running infra/identity/pe/down needs: Owner on TEST_SUB; Owner (or User Access
# Administrator + Private DNS Zone Contributor) on SHARED_SUB or the DNS RG; and Entra
# rights to create an app registration (Application Developer, or user app registration
# allowed). Run from Azure Cloud Shell (bash) or any shell with bash >= 4, az and jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/pldns-test.env}"
STATE_DIR="$SCRIPT_DIR/.pldns-test"
BUILD_DIR="$STATE_DIR/build"

# ---------------------------------------------------------------- helpers
log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { printf '    \033[31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "'$1' is required"; }

[[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE (copy pldns-test.env.example)"
# shellcheck source=/dev/null
source "$ENV_FILE"
for v in TEST_SUB SHARED_SUB LOCATION LOCATION_SHORT PREFIX DNS_RG TEST_RG VNET_CIDR PE_SUBNET_CIDR VM_SUBNET_CIDR SERVICES; do
  [[ -n "${!v:-}" ]] || die "$v is not set in $ENV_FILE"
done
[[ "$PREFIX" =~ ^[a-z]{1,6}$ ]] || die "PREFIX must be 1-6 lowercase letters"
HUB_VNET_ID="${HUB_VNET_ID:-}"
ENABLE_VM="${ENABLE_VM:-true}"
DNS_EFFECT="${DNS_EFFECT:-DeployIfNotExists}"
DENY_EFFECT="${DENY_EFFECT:-Deny}"
WAIT_MINUTES="${WAIT_MINUTES:-45}"
PURGE_DNS="${PURGE_DNS:-false}"

# Deterministic, globally unique-ish suffix so every step derives the same names
SFX="$(printf '%s' "$TEST_SUB" | sha1sum | cut -c1-6)"
TEST_SCOPE="/subscriptions/$TEST_SUB"
DNS_RG_ID="/subscriptions/$SHARED_SUB/resourceGroups/$DNS_RG"
DEF_PREFIX="$TEST_SCOPE/providers/Microsoft.Authorization/policyDefinitions"

VNET="vnet-$PREFIX-test"
VM="vm-$PREFIX-test"
SA="st${PREFIX}${SFX}"
KV="kv-$PREFIX-$SFX"
ACR="acr${PREFIX}${SFX}"
SQL="sql-$PREFIX-$SFX"
COSMOS="cosmos-$PREFIX-$SFX"
UAMI="id-$PREFIX-remediation-test"
SP_NAME="sp-$PREFIX-policy-deployer-test"
INIT_NAME="$PREFIX-private-link-dns-test"
ASSIGN_NAME="$PREFIX-pl-dns-test"
ASSIGN_ID="$TEST_SCOPE/providers/Microsoft.Authorization/policyAssignments/$ASSIGN_NAME"
LINK_NAME="link-$PREFIX-test"
TAG="createdBy=$PREFIX-test"

DEF_CUSTOM="deploy-pe-dns-zonegroup-central"
DEF_DENY="deny-privatelink-dns-zones-outside-hub"

# Same defaults as root/variables.tf (private_dns_builtin_exclude, private_dns_custom_zones)
EXCLUDE_JSON='["DINE-Private-DNS-Azure-IoT","DINE-Private-DNS-Azure-IoTCentral","DINE-Private-DNS-Azure-IoTDeviceupdate","DINE-Private-DNS-Azure-IoTHubs","DINE-Private-DNS-Azure-Storage-Table","DINE-Private-DNS-Azure-DataFactory-Portal"]'
CUSTOM_ZONES_JSON='{
  "microsoft.storage/storageaccounts/table": ["privatelink.table.core.windows.net"],
  "microsoft.datafactory/factories/portal": ["privatelink.adf.azure.com"],
  "microsoft.sql/servers/sqlserver": ["privatelink.database.windows.net"],
  "microsoft.dbforpostgresql/flexibleservers/postgresqlserver": ["privatelink.postgres.database.azure.com"],
  "microsoft.dbformysql/flexibleservers/mysqlserver": ["privatelink.mysql.database.azure.com"],
  "microsoft.apimanagement/service/gateway": ["privatelink.azure-api.net"],
  "microsoft.purview/accounts/account": ["privatelink.purview.azure.com"],
  "microsoft.purview/accounts/portal": ["privatelink.purviewstudio.azure.com"]
}'

# Role names (built-in) — names, not GUIDs, so nothing to mistype
R_POLICY="Resource Policy Contributor"
R_MIOP="Managed Identity Operator"
R_NET="Network Contributor"
R_DNS="Private DNS Zone Contributor"
R_READ="Reader"

has_service() { [[ " $SERVICES " == *" $1 "* ]]; }

zone_for() { # service -> zone name
  case "$1" in
    blob) echo privatelink.blob.core.windows.net ;;
    file) echo privatelink.file.core.windows.net ;;
    queue) echo privatelink.queue.core.windows.net ;;
    table) echo privatelink.table.core.windows.net ;;
    vault) echo privatelink.vaultcore.azure.net ;;
    acr) echo privatelink.azurecr.io ;;
    sql) echo privatelink.database.windows.net ;;
    cosmos) echo privatelink.table.cosmos.azure.com ;;
    *) die "unknown service '$1'" ;;
  esac
}

test_zones() { local s; for s in $SERVICES; do zone_for "$s"; done | sort -u; }

# Run az as the deployer SPN, from its own config dir (never touches your login)
sp_env() { [[ -f "$STATE_DIR/sp.env" ]] || die "Run 'identity' first"; # shellcheck source=/dev/null
  source "$STATE_DIR/sp.env"; }
as_sp() { AZURE_CONFIG_DIR="$STATE_DIR/az-sp" az "$@"; }
sp_login() {
  sp_env
  local i
  for i in $(seq 1 12); do
    if as_sp login --service-principal -u "$SP_APP_ID" -p "$SP_SECRET" --tenant "$TENANT_ID" -o none 2>/dev/null; then
      as_sp account set --subscription "$TEST_SUB"
      info "Logged in as $SP_NAME ($SP_APP_ID) in an isolated az profile"
      return 0
    fi
    info "SPN sign-in not ready yet (Entra replication), retry $i/12"; sleep 15
  done
  die "Could not sign in as the deployer SPN"
}

# Idempotent role assignment by object ID (avoids Graph lookups and replication races)
ensure_role() { # principalObjectId role scope [subscription]
  local pid="$1" role="$2" scope="$3" sub="${4:-$TEST_SUB}" n i
  n=$(az role assignment list --subscription "$sub" --assignee "$pid" --role "$role" --scope "$scope" --query "length(@)" -o tsv 2>/dev/null || echo 0)
  if [[ "$n" -gt 0 ]]; then info "exists   $role @ $scope"; return 0; fi
  for i in $(seq 1 10); do
    if az role assignment create --subscription "$sub" --assignee-object-id "$pid" --assignee-principal-type ServicePrincipal \
         --role "$role" --scope "$scope" --description "$PREFIX policy test" -o none 2>"$STATE_DIR/ra.err"; then
      info "granted  $role @ $scope"; return 0
    fi
    grep -q -i -E 'PrincipalNotFound|does not exist in the directory' "$STATE_DIR/ra.err" || { cat "$STATE_DIR/ra.err" >&2; die "role assignment failed"; }
    info "principal not replicated yet, retry $i/10"; sleep 15
  done
  die "role assignment kept failing: $role @ $scope"
}

pe_create() { # resourceName resourceId groupId
  local name="pe-$1-$3"
  if az network private-endpoint show -g "$TEST_RG" -n "$name" --subscription "$TEST_SUB" -o none 2>/dev/null; then
    info "exists   $name"; return 0
  fi
  # Deliberately NO --private-dns-zone integration: the policy must do it.
  az network private-endpoint create -g "$TEST_RG" -n "$name" -l "$LOCATION" --subscription "$TEST_SUB" \
    --vnet-name "$VNET" --subnet snet-pe --private-connection-resource-id "$2" \
    --group-id "$3" --connection-name "pec-$1-$3" --tags "$TAG" -o none
  printf '%s\t%s\n' "$name" "$(date +%s)" >> "$STATE_DIR/pe-created.tsv"
  info "created  $name"
}

future_utc() { # +1 day, GNU or BSD date
  date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+1d +%Y-%m-%dT%H:%M:%SZ
}

# ---------------------------------------------------------------- steps
cmd_infra() {
  log "Shared subscription: DNS RG and zones"
  az group create -n "$DNS_RG" -l "$LOCATION" --subscription "$SHARED_SUB" --tags "$TAG" -o none
  local z
  for z in $(test_zones); do
    if az network private-dns zone show -g "$DNS_RG" -n "$z" --subscription "$SHARED_SUB" -o none 2>/dev/null; then
      info "exists   $z"
    else
      az network private-dns zone create -g "$DNS_RG" -n "$z" --subscription "$SHARED_SUB" --tags "$TAG" -o none
      info "created  $z"
    fi
  done

  log "Test subscription: RG, VNet, subnets"
  az group create -n "$TEST_RG" -l "$LOCATION" --subscription "$TEST_SUB" --tags "$TAG" -o none
  az network vnet create -g "$TEST_RG" -n "$VNET" -l "$LOCATION" --subscription "$TEST_SUB" \
    --address-prefixes "$VNET_CIDR" --subnet-name snet-pe --subnet-prefixes "$PE_SUBNET_CIDR" --tags "$TAG" -o none
  az network vnet subnet create -g "$TEST_RG" --vnet-name "$VNET" -n snet-vm --address-prefixes "$VM_SUBNET_CIDR" \
    --subscription "$TEST_SUB" -o none 2>/dev/null || true
  local vnet_id; vnet_id=$(az network vnet show -g "$TEST_RG" -n "$VNET" --subscription "$TEST_SUB" --query id -o tsv)

  log "Link zones to the test VNet${HUB_VNET_ID:+ and the hub VNet}"
  for z in $(test_zones); do
    az network private-dns link vnet show -g "$DNS_RG" -z "$z" -n "$LINK_NAME" --subscription "$SHARED_SUB" -o none 2>/dev/null \
      || az network private-dns link vnet create -g "$DNS_RG" -z "$z" -n "$LINK_NAME" -v "$vnet_id" -e false \
           --subscription "$SHARED_SUB" -o none
    if [[ -n "$HUB_VNET_ID" ]]; then
      az network private-dns link vnet show -g "$DNS_RG" -z "$z" -n "link-$PREFIX-hub" --subscription "$SHARED_SUB" -o none 2>/dev/null \
        || az network private-dns link vnet create -g "$DNS_RG" -z "$z" -n "link-$PREFIX-hub" -v "$HUB_VNET_ID" -e false \
             --subscription "$SHARED_SUB" -o none
    fi
    info "linked   $z"
  done

  if [[ "$ENABLE_VM" == "true" ]]; then
    log "Test VM (no public IP; used through run-command)"
    az vm show -g "$TEST_RG" -n "$VM" --subscription "$TEST_SUB" -o none 2>/dev/null \
      || az vm create -g "$TEST_RG" -n "$VM" -l "$LOCATION" --subscription "$TEST_SUB" --image Ubuntu2204 \
           --size Standard_B1s --vnet-name "$VNET" --subnet snet-vm --public-ip-address "" --nsg "" \
           --admin-username azureuser --generate-ssh-keys --tags "$TAG" -o none
  fi

  log "Storage account + PRE-EXISTING queue endpoint (created before the policy; remediation must fix it)"
  az storage account show -n "$SA" -g "$TEST_RG" --subscription "$TEST_SUB" -o none 2>/dev/null \
    || az storage account create -n "$SA" -g "$TEST_RG" -l "$LOCATION" --subscription "$TEST_SUB" --sku Standard_LRS \
         --kind StorageV2 --public-network-access Disabled --allow-shared-key-access false --min-tls-version TLS1_2 --tags "$TAG" -o none
  local sa_id; sa_id=$(az storage account show -n "$SA" -g "$TEST_RG" --subscription "$TEST_SUB" --query id -o tsv)
  has_service queue && pe_create "$SA" "$sa_id" queue
  log "infra done. Next: identity"
}

cmd_identity() {
  local tenant; tenant=$(az account show --query tenantId -o tsv)

  log "Deployer SPN: $SP_NAME"
  local app_id sp_oid secret
  app_id=$(az ad app list --display-name "$SP_NAME" --query "[0].appId" -o tsv)
  if [[ -z "$app_id" ]]; then
    app_id=$(az ad app create --display-name "$SP_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv)
    info "created  app registration $app_id"
  else
    info "exists   app registration $app_id"
  fi
  sp_oid=$(az ad sp show --id "$app_id" --query id -o tsv 2>/dev/null || true)
  [[ -n "$sp_oid" ]] || sp_oid=$(az ad sp create --id "$app_id" --query id -o tsv)
  # Replaces any previous secret on this TEST app; expires in 24h.
  secret=$(az ad app credential reset --id "$app_id" --display-name "$PREFIX-test-24h" --end-date "$(future_utc)" --query password -o tsv)
  umask 077
  cat > "$STATE_DIR/sp.env" <<EOF
SP_APP_ID="$app_id"
SP_OBJECT_ID="$sp_oid"
TENANT_ID="$tenant"
SP_SECRET="$secret"
EOF
  info "secret   written to $STATE_DIR/sp.env (mode 600, expires in 24h, deleted by 'down')"

  log "Remediation identity: $UAMI"
  az identity show -g "$TEST_RG" -n "$UAMI" --subscription "$TEST_SUB" -o none 2>/dev/null \
    || az identity create -g "$TEST_RG" -n "$UAMI" -l "$LOCATION" --subscription "$TEST_SUB" --tags "$TAG" -o none
  local uami_id uami_pid
  uami_id=$(az identity show -g "$TEST_RG" -n "$UAMI" --subscription "$TEST_SUB" --query id -o tsv)
  uami_pid=$(az identity show -g "$TEST_RG" -n "$UAMI" --subscription "$TEST_SUB" --query principalId -o tsv)
  printf 'UAMI_ID="%s"\nUAMI_PRINCIPAL_ID="%s"\n' "$uami_id" "$uami_pid" >> "$STATE_DIR/sp.env"

  log "RBAC: deployer SPN (no role-assignment rights)"
  ensure_role "$sp_oid" "$R_POLICY" "$TEST_SCOPE"        # definitions, initiative, assignment, exemptions, remediation, */read
  ensure_role "$sp_oid" "$R_MIOP"   "$uami_id"           # attach THIS identity to the assignment, nothing else

  log "RBAC: remediation identity (what the initiative's DINE policies declare)"
  ensure_role "$uami_pid" "$R_NET"  "$TEST_SCOPE"                 # zone groups on endpoints
  ensure_role "$uami_pid" "$R_DNS"  "$TEST_SCOPE"                 # File Sync built-in declares it (parity with prod)
  ensure_role "$uami_pid" "$R_READ" "$TEST_SCOPE"                 # SQL MI policy reads the instance
  ensure_role "$uami_pid" "$R_NET"  "$DNS_RG_ID" "$SHARED_SUB"    # zone group -> zone join
  ensure_role "$uami_pid" "$R_DNS"  "$DNS_RG_ID" "$SHARED_SUB"    # A records in the central zones
  log "identity done. Role assignments can take a few minutes to apply. Next: deploy"
}

build_policy_json() {
  mkdir -p "$BUILD_DIR"
  local cat="$REPO_DIR/lib/builtin-private-dns/catalog.json" f
  [[ -f "$cat" ]] || die "catalog not found at $cat"

  # Custom definitions: split native JSON into the pieces az expects
  for f in "$DEF_CUSTOM" "$DEF_DENY"; do
    jq '.properties.policyRule' "$REPO_DIR/lib/definitions/network/$f.json" > "$BUILD_DIR/$f.rules.json"
    jq '.properties.parameters' "$REPO_DIR/lib/definitions/network/$f.json" > "$BUILD_DIR/$f.params.json"
  done

  # Same guard as Terraform: a custom key must not target a groupId that a built-in
  # without a provider check would also act on.
  local overlap
  overlap=$(jq -r --slurpfile c "$cat" --argjson ex "$EXCLUDE_JSON" --argjson cz "$CUSTOM_ZONES_JSON" -n '
    [ $c[0].references[] | select((.reference_id as $r | $ex | index($r)) | not) | select(.deprecated | not)
      | select((.provider_filter | length) == 0)
      | (.group_ids_matched + [ .fixed_parameters | to_entries[]
          | select(.key | test("^(groupId|privateEndpointGroupId|targetSubResource|listOfGroupIds)$")) | .value
          | if type == "array" then .[] else . end ]) | .[] | ascii_downcase ] as $g
    | [ $cz | keys[] | select((split("/")[2]) as $k | $g | index($k)) ] | join(", ")')
  [[ -z "$overlap" ]] || die "custom zone keys overlap groupId-only built-ins: $overlap"

  jq -n --slurpfile c "$cat" --argjson ex "$EXCLUDE_JSON" --argjson cz "$CUSTOM_ZONES_JSON" \
    --arg region "$LOCATION" --arg code "$LOCATION_SHORT" --arg dnsrg "$DNS_RG_ID" --arg defp "$DEF_PREFIX" \
    --arg dcustom "$DEF_CUSTOM" --arg ddeny "$DEF_DENY" --arg dnse "$DNS_EFFECT" --arg denye "$DENY_EFFECT" '
    def render: gsub("\\{regionName\\}"; $region) | gsub("\\{regionCode\\}"; $code);
    def zid: $dnsrg + "/providers/Microsoft.Network/privateDnsZones/" + .;
    def p($n): "[parameters(\u0027" + $n + "\u0027)]";
    ($c[0].references | map(select((.reference_id as $r | $ex | index($r)) | not) | select(.deprecated | not))) as $refs
    | ($refs | map(.zone_parameters | to_entries[] | .value) | unique_by(.zone_key)) as $zp
    | {
        definitions: (
          ($refs | map({
            policyDefinitionId: .definition_id,
            policyDefinitionReferenceId: .reference_id,
            parameters: ({ effect: { value: p("dnsEffect") } }
              + (.zone_parameters | with_entries(.value = { value: p(.value.zone_key) }))
              + (.fixed_parameters | with_entries(.value = { value: .value })))
          }))
          + [
            { policyDefinitionId: ($defp + "/" + $dcustom), policyDefinitionReferenceId: "DINE-Private-DNS-Custom-Generic",
              parameters: { privateDnsZoneMap: { value: p("privateDnsZoneMap") },
                            centralDnsResourceGroupId: { value: p("centralDnsResourceGroupId") },
                            effect: { value: p("dnsEffect") } } },
            { policyDefinitionId: ($defp + "/" + $ddeny), policyDefinitionReferenceId: "Deny-PrivateLink-Zones-In-LZ",
              parameters: { effect: { value: p("denyEffect") } } }
          ]),
        params: ({
            dnsEffect: { type: "String", allowedValues: ["DeployIfNotExists", "AuditIfNotExists", "Disabled"], defaultValue: "AuditIfNotExists" },
            denyEffect: { type: "String", allowedValues: ["Deny", "Audit", "Disabled"], defaultValue: "Audit" },
            privateDnsZoneMap: { type: "Object" },
            centralDnsResourceGroupId: { type: "String" }
          } + ($zp | map({ key: .zone_key, value: { type: "String", metadata: { displayName: .zone_key } } }) | from_entries)),
        values: ({
            dnsEffect: { value: $dnse },
            denyEffect: { value: $denye },
            privateDnsZoneMap: { value: ($cz | with_entries(.value |= map(zid))) },
            centralDnsResourceGroupId: { value: $dnsrg }
          } + ($zp | map({ key: .zone_key, value: { value: (.zone_name | render | zid) } }) | from_entries)),
        count: ($refs | length)
      }' > "$BUILD_DIR/initiative.all.json"

  jq '.definitions' "$BUILD_DIR/initiative.all.json" > "$BUILD_DIR/initiative.definitions.json"
  jq '.params'      "$BUILD_DIR/initiative.all.json" > "$BUILD_DIR/initiative.params.json"
  jq '.values'      "$BUILD_DIR/initiative.all.json" > "$BUILD_DIR/assignment.params.json"
  info "built initiative: $(jq .count "$BUILD_DIR/initiative.all.json") built-ins + custom generic + deny, $(jq 'length' "$BUILD_DIR/initiative.params.json") parameters"
}

cmd_deploy() {
  sp_login; sp_env
  build_policy_json

  log "Custom definitions (as SPN)"
  local f
  for f in "$DEF_CUSTOM" "$DEF_DENY"; do
    as_sp policy definition create --name "$f" --subscription "$TEST_SUB" \
      --display-name "$(jq -r .properties.displayName "$REPO_DIR/lib/definitions/network/$f.json")" \
      --description "$(jq -r .properties.description "$REPO_DIR/lib/definitions/network/$f.json")" \
      --mode "$(jq -r .properties.mode "$REPO_DIR/lib/definitions/network/$f.json")" \
      --rules "$BUILD_DIR/$f.rules.json" --params "$BUILD_DIR/$f.params.json" \
      --metadata "{\"category\":\"Network\",\"createdBy\":\"$PREFIX-test\"}" -o none
    info "upserted $f"
  done

  log "Initiative (as SPN)"
  as_sp policy set-definition create --name "$INIT_NAME" --subscription "$TEST_SUB" \
    --display-name "Private Link DNS integration (test)" \
    --description "Test copy of the Terraform initiative; built from catalog.json" \
    --definitions "$BUILD_DIR/initiative.definitions.json" --params "$BUILD_DIR/initiative.params.json" \
    --metadata "{\"category\":\"Network\",\"createdBy\":\"$PREFIX-test\"}" -o none
  info "upserted $INIT_NAME"

  log "Assignment at $TEST_SCOPE with the remediation UAMI (as SPN)"
  as_sp policy assignment create --name "$ASSIGN_NAME" --scope "$TEST_SCOPE" \
    --display-name "Private Link DNS integration (test)" \
    --policy-set-definition "$TEST_SCOPE/providers/Microsoft.Authorization/policySetDefinitions/$INIT_NAME" \
    --params "$BUILD_DIR/assignment.params.json" --mi-user-assigned "$UAMI_ID" --location "$LOCATION" \
    --enforcement-mode Default -o none
  as_sp policy assignment non-compliance-message create --name "$ASSIGN_NAME" --scope "$TEST_SCOPE" \
    -m "Private endpoints must register in the central privatelink zones; privatelink.* zones are not allowed here." -o none 2>/dev/null || true
  info "assigned $ASSIGN_ID"
  log "deploy done. New assignments are not instant. Next: deny-test (it waits until the assignment is live)"
}

cmd_deny_test() {
  log "Deny test: creating privatelink.blob.core.windows.net in $TEST_RG must be blocked"
  local deadline=$(( $(date +%s) + WAIT_MINUTES * 60 )) err="$STATE_DIR/deny.err"
  while (( $(date +%s) < deadline )); do
    if az network private-dns zone create -g "$TEST_RG" -n privatelink.blob.core.windows.net --subscription "$TEST_SUB" -o none 2>"$err"; then
      az network private-dns zone delete -g "$TEST_RG" -n privatelink.blob.core.windows.net --subscription "$TEST_SUB" --yes -o none
      info "allowed (assignment not live yet); removed it, retrying in 60s"
      sleep 60; continue
    fi
    if grep -q RequestDisallowedByPolicy "$err"; then
      ok "denied by policy (POC-15). The assignment is live: run 'pe' next."
      grep -o -E '"message":"[^"]{0,200}' "$err" | head -1 | sed 's/^/    /' || true
      return 0
    fi
    cat "$err" >&2; die "unexpected error"
  done
  bad "still allowed after $WAIT_MINUTES minutes"; return 1
}

cmd_pe() {
  log "Test services and private endpoints (no DNS integration: the policy must add it)"
  touch "$STATE_DIR/pe-created.tsv"
  local id me_id me_upn g
  if has_service blob || has_service file || has_service table; then
    id=$(az storage account show -n "$SA" -g "$TEST_RG" --subscription "$TEST_SUB" --query id -o tsv)
    for g in blob file table; do has_service "$g" && pe_create "$SA" "$id" "$g"; done
  fi
  if has_service vault; then
    az keyvault show -n "$KV" --subscription "$TEST_SUB" -o none 2>/dev/null \
      || az keyvault create -n "$KV" -g "$TEST_RG" -l "$LOCATION" --subscription "$TEST_SUB" \
           --enable-rbac-authorization true --public-network-access Disabled --tags "$TAG" -o none
    pe_create "$KV" "$(az keyvault show -n "$KV" --subscription "$TEST_SUB" --query id -o tsv)" vault
  fi
  if has_service acr; then  # private endpoints need the Premium SKU
    az acr show -n "$ACR" --subscription "$TEST_SUB" -o none 2>/dev/null \
      || az acr create -n "$ACR" -g "$TEST_RG" -l "$LOCATION" --subscription "$TEST_SUB" --sku Premium \
           --public-network-enabled false --tags "$TAG" -o none
    pe_create "$ACR" "$(az acr show -n "$ACR" --subscription "$TEST_SUB" --query id -o tsv)" registry
  fi
  if has_service sql; then  # Entra-only auth, you as admin, no public access
    me_id=$(az ad signed-in-user show --query id -o tsv); me_upn=$(az ad signed-in-user show --query userPrincipalName -o tsv)
    az sql server show -n "$SQL" -g "$TEST_RG" --subscription "$TEST_SUB" -o none 2>/dev/null \
      || az sql server create -n "$SQL" -g "$TEST_RG" -l "$LOCATION" --subscription "$TEST_SUB" \
           --enable-ad-only-auth --external-admin-principal-type User --external-admin-name "$me_upn" \
           --external-admin-sid "$me_id" --enable-public-network false -o none
    pe_create "$SQL" "$(az sql server show -n "$SQL" -g "$TEST_RG" --subscription "$TEST_SUB" --query id -o tsv)" sqlServer
  fi
  if has_service cosmos; then  # Table API: proves Storage-table vs Cosmos-table land in different zones
    az cosmosdb show -n "$COSMOS" -g "$TEST_RG" --subscription "$TEST_SUB" -o none 2>/dev/null \
      || az cosmosdb create -n "$COSMOS" -g "$TEST_RG" --subscription "$TEST_SUB" --capabilities EnableTable \
           --locations regionName="$LOCATION" failoverPriority=0 isZoneRedundant=False --public-network-access DISABLED --tags "$TAG" -o none
    pe_create "$COSMOS" "$(az cosmosdb show -n "$COSMOS" -g "$TEST_RG" --subscription "$TEST_SUB" --query id -o tsv)" Table
  fi
  log "pe done. Next: verify (waits up to $WAIT_MINUTES min for the policy to register each endpoint)"
}

expected_zone() { # privateLinkServiceId groupId
  local rid="${1,,}" g="${2,,}"
  case "$g" in
    blob) echo privatelink.blob.core.windows.net ;;
    file) echo privatelink.file.core.windows.net ;;
    queue) echo privatelink.queue.core.windows.net ;;
    table) [[ "$rid" == *microsoft.documentdb* ]] && echo privatelink.table.cosmos.azure.com || echo privatelink.table.core.windows.net ;;
    vault) echo privatelink.vaultcore.azure.net ;;
    registry) echo privatelink.azurecr.io ;;
    sqlserver) echo privatelink.database.windows.net ;;
    *) echo "?" ;;
  esac
}

pe_fqdn() { # resourceName groupId zone -> public FQDN clients use
  local n="$1" g="${2,,}"
  case "$g" in
    blob|file|queue) echo "$n.$g.core.windows.net" ;;
    table) [[ "$3" == *cosmos* ]] && echo "$n.table.cosmos.azure.com" || echo "$n.table.core.windows.net" ;;
    vault) echo "$n.vault.azure.net" ;;
    registry) echo "$n.azurecr.io" ;;
    sqlserver) echo "$n.database.windows.net" ;;
  esac
}

cmd_verify() {
  log "Verify: zone group -> central zone -> A record = endpoint IP (POC-05..09, POC-11, POC-14)"
  local deadline=$(( $(date +%s) + WAIT_MINUTES * 60 )) all_done pes pe
  pes=$(az network private-endpoint list -g "$TEST_RG" --subscription "$TEST_SUB" --query "[?tags.createdBy=='$PREFIX-test'].name" -o tsv)
  [[ -n "$pes" ]] || die "no test endpoints found; run infra/pe first"
  declare -A seen
  while :; do
    all_done=true
    for pe in $pes; do
      [[ -n "${seen[$pe]:-}" ]] && continue
      local zg; zg=$(az network private-endpoint dns-zone-group list -g "$TEST_RG" --endpoint-name "$pe" --subscription "$TEST_SUB" --query "[0].name" -o tsv 2>/dev/null)
      if [[ -n "$zg" ]]; then
        local created now; created=$(awk -F'\t' -v n="$pe" '$1==n{print $2}' "$STATE_DIR/pe-created.tsv" 2>/dev/null | tail -1); now=$(date +%s)
        seen[$pe]="${created:+$(( now - created ))}"; seen[$pe]="${seen[$pe]:-n/a}"
      else
        all_done=false
      fi
    done
    $all_done && break
    (( $(date +%s) >= deadline )) && break
    info "waiting for zone groups: $(for pe in $pes; do [[ -z "${seen[$pe]:-}" ]] && printf '%s ' "$pe"; done)"
    sleep 30
  done

  printf '\n    %-34s %-10s %-38s %-16s %-8s %s\n' ENDPOINT GROUP ZONE RECORD_IP SECS RESULT
  local fails=0 fqdns=""
  for pe in $pes; do
    local js rid g ip zone exp zid rec res
    js=$(az network private-endpoint show -g "$TEST_RG" -n "$pe" --subscription "$TEST_SUB" -o json)
    rid=$(jq -r '(.privateLinkServiceConnections + .manualPrivateLinkServiceConnections)[0].privateLinkServiceId' <<<"$js")
    g=$(jq -r '(.privateLinkServiceConnections + .manualPrivateLinkServiceConnections)[0].groupIds[0]' <<<"$js")
    ip=$(az network nic show --ids "$(jq -r '.networkInterfaces[0].id' <<<"$js")" --query "ipConfigurations[0].privateIPAddress" -o tsv)
    exp=$(expected_zone "$rid" "$g")
    zid=$(az network private-endpoint dns-zone-group list -g "$TEST_RG" --endpoint-name "$pe" --subscription "$TEST_SUB" \
            --query "[0].privateDnsZoneConfigs[0].privateDnsZoneId" -o tsv 2>/dev/null || true)
    zone="${zid##*/}"; rec="-"; res=FAIL
    if [[ -n "$zid" ]]; then
      rec=$(az network private-dns record-set a show -g "$DNS_RG" -z "$exp" -n "${rid##*/}" --subscription "$SHARED_SUB" \
              --query "aRecords[0].ipv4Address" -o tsv 2>/dev/null || echo "-")
      if [[ "${zid,,}" == "${DNS_RG_ID,,}/providers/microsoft.network/privatednszones/${exp,,}" && "$rec" == "$ip" ]]; then res=PASS; fi
    fi
    [[ "$res" == PASS ]] || fails=$((fails + 1))
    printf '    %-34s %-10s %-38s %-16s %-8s %s\n' "$pe" "$g" "${zone:-none (expected $exp)}" "$rec" "${seen[$pe]:-timeout}" "$res"
    fqdns+="$(pe_fqdn "${rid##*/}" "$g" "$exp")=$ip "
  done

  if [[ "$ENABLE_VM" == "true" ]] && az vm show -g "$TEST_RG" -n "$VM" --subscription "$TEST_SUB" -o none 2>/dev/null; then
    log "Name resolution from $VM (POC-17 equivalent inside the test VNet)"
    local script out name want got
    script="for p in $fqdns; do n=\${p%%=*}; printf '%s %s\n' \"\$n\" \"\$(getent hosts \$n | awk '{print \$1}' | head -1)\"; done"
    out=$(az vm run-command invoke -g "$TEST_RG" -n "$VM" --subscription "$TEST_SUB" --command-id RunShellScript \
            --scripts "$script" --query "value[0].message" -o tsv)
    while read -r name got; do
      [[ "$name" == *.* ]] || continue
      want=$(tr ' ' '\n' <<<"$fqdns" | awk -F= -v n="$name" '$1==n{print $2}')
      if [[ -n "$got" && "$got" == "$want" ]]; then ok "$name -> $got"; else bad "$name -> ${got:-no answer} (expected $want)"; fails=$((fails + 1)); fi
    done <<<"$(sed -n '/\[stdout\]/,/\[stderr\]/p' <<<"$out")"
  fi

  if (( fails == 0 )); then log "verify: all checks passed"; else log "verify: $fails check(s) failed"; info "A pre-existing endpoint (queue) stays FAIL until 'remediate' has run."; return 1; fi
}

cmd_remediate() {
  sp_login
  log "Compliance scan (as SPN; can take several minutes)"
  as_sp policy state trigger-scan --subscription "$TEST_SUB" -o none
  local refs ref name
  refs=$(as_sp policy state list --subscription "$TEST_SUB" \
           --filter "policyAssignmentName eq '$ASSIGN_NAME' and complianceState eq 'NonCompliant'" \
           --query "[].policyDefinitionReferenceId" -o tsv | sort -u | grep -v -i '^Deny-' || true)
  if [[ -z "$refs" ]]; then info "nothing non-compliant"; return 0; fi
  log "Remediation tasks (as SPN)"
  for ref in $refs; do
    name="rem-$(tr '[:upper:]' '[:lower:]' <<<"$ref" | tr -c 'a-z0-9-' '-' | cut -c1-48)-$(date +%s)"
    as_sp policy remediation create --name "$name" --subscription "$TEST_SUB" --policy-assignment "$ASSIGN_ID" \
      --definition-reference-id "$ref" --resource-discovery-mode ExistingNonCompliant -o none
    info "started  $name"
  done
  log "Waiting for remediation tasks"
  local deadline=$(( $(date +%s) + WAIT_MINUTES * 60 )) running
  while (( $(date +%s) < deadline )); do
    running=$(as_sp policy remediation list --subscription "$TEST_SUB" \
                --query "[?policyAssignmentId=='$ASSIGN_ID' && (provisioningState=='Accepted' || provisioningState=='Evaluating' || provisioningState=='Running')] | length(@)" -o tsv)
    [[ "$running" == 0 ]] && break
    info "$running task(s) still running"; sleep 30
  done
  as_sp policy remediation list --subscription "$TEST_SUB" --query "[?policyAssignmentId=='$ASSIGN_ID'].{task:name, ref:policyDefinitionReferenceId, state:provisioningState, ok:deploymentStatus.successfulDeployments, failed:deploymentStatus.failedDeployments}" -o table
  log "remediate done. Run verify again: the pre-existing queue endpoint should now PASS (POC-14)"
}

cmd_status() {
  sp_login
  log "Non-compliant references for $ASSIGN_NAME"
  as_sp policy state summarize --subscription "$TEST_SUB" --filter "policyAssignmentName eq '$ASSIGN_NAME'" \
    --query "policyAssignments[0].policyDefinitions[?results.nonCompliantResources > \`0\`].{reference:policyDefinitionReferenceId, nonCompliant:results.nonCompliantResources}" -o table
  log "Remediation tasks"
  as_sp policy remediation list --subscription "$TEST_SUB" --query "[?policyAssignmentId=='$ASSIGN_ID'].{task:name, state:provisioningState, failed:deploymentStatus.failedDeployments}" -o table
}

cmd_rbac_check() {
  sp_env
  log "Role assignments held by the deployer SPN and the remediation UAMI (POC-03)"
  local name pid expected role scope fails=0 sub
  for name in SPN UAMI; do
    if [[ "$name" == SPN ]]; then
      pid="$SP_OBJECT_ID"
      expected=$(printf '%s\n' "$R_POLICY|${TEST_SCOPE,,}" "$R_MIOP|${UAMI_ID,,}")
    else
      pid="$UAMI_PRINCIPAL_ID"
      expected=$(printf '%s\n' "$R_NET|${TEST_SCOPE,,}" "$R_DNS|${TEST_SCOPE,,}" "$R_READ|${TEST_SCOPE,,}" \
                               "$R_NET|${DNS_RG_ID,,}" "$R_DNS|${DNS_RG_ID,,}")
    fi
    info "$name ($pid)"
    for sub in "$TEST_SUB" "$SHARED_SUB"; do
      while IFS=$'\t' read -r role scope; do
        [[ -n "$role" ]] || continue
        if grep -qxF "$role|${scope,,}" <<<"$expected"; then ok "$role @ $scope"
        else bad "UNEXPECTED $role @ $scope"; fails=$((fails + 1)); fi
      done < <(az role assignment list --subscription "$sub" --assignee "$pid" --all \
                 --query "[].[roleDefinitionName, scope]" -o tsv 2>/dev/null | sort -u)
    done
  done
  if (( fails == 0 )); then log "rbac-check: only the expected roles are held"; else log "rbac-check: $fails unexpected role assignment(s)"; return 1; fi
}

cmd_down() {
  log "Removing the policy objects"
  az policy assignment delete --name "$ASSIGN_NAME" --scope "$TEST_SCOPE" -o none 2>/dev/null && info "deleted  assignment" || true
  az policy set-definition delete --name "$INIT_NAME" --subscription "$TEST_SUB" -o none 2>/dev/null && info "deleted  initiative" || true
  local f; for f in "$DEF_CUSTOM" "$DEF_DENY"; do
    az policy definition delete --name "$f" --subscription "$TEST_SUB" -o none 2>/dev/null && info "deleted  $f" || true
  done

  if [[ -f "$STATE_DIR/sp.env" ]]; then
    sp_env
    log "Removing role assignments (before the principals disappear, so none are orphaned)"
    local pid sub
    for pid in "${SP_OBJECT_ID:-}" "${UAMI_PRINCIPAL_ID:-}"; do
      [[ -n "$pid" ]] || continue
      for sub in "$TEST_SUB" "$SHARED_SUB"; do
        az role assignment list --subscription "$sub" --assignee "$pid" --all --query "[].id" -o tsv 2>/dev/null \
          | while read -r id; do [[ -n "$id" ]] && az role assignment delete --ids "$id" -o none && info "deleted  $id"; done
      done
    done
    log "Deleting the deployer app registration"
    az ad app delete --id "$SP_APP_ID" -o none 2>/dev/null && info "deleted  $SP_NAME" || true
  fi

  log "Removing zone links to the test VNet"
  local z
  for z in $(test_zones); do
    az network private-dns link vnet delete -g "$DNS_RG" -z "$z" -n "$LINK_NAME" --subscription "$SHARED_SUB" --yes -o none 2>/dev/null && info "unlinked $z" || true
    [[ -n "$HUB_VNET_ID" ]] && az network private-dns link vnet delete -g "$DNS_RG" -z "$z" -n "link-$PREFIX-hub" --subscription "$SHARED_SUB" --yes -o none 2>/dev/null || true
  done

  log "Deleting $TEST_RG (endpoints, zone groups and their A records go with it)"
  az group delete -n "$TEST_RG" --subscription "$TEST_SUB" --yes -o none 2>/dev/null && info "deleted  $TEST_RG" || true
  if has_service vault; then
    az keyvault purge -n "$KV" -l "$LOCATION" --subscription "$TEST_SUB" -o none 2>/dev/null && info "purged   $KV" || true
  fi

  if [[ "$PURGE_DNS" == "true" ]]; then
    log "PURGE_DNS=true: deleting zones this script created"
    for z in $(az network private-dns zone list -g "$DNS_RG" --subscription "$SHARED_SUB" --query "[?tags.createdBy=='$PREFIX-test'].name" -o tsv 2>/dev/null); do
      az network private-dns zone delete -g "$DNS_RG" -n "$z" --subscription "$SHARED_SUB" --yes -o none && info "deleted  $z"
    done
    if [[ "$(az group show -n "$DNS_RG" --subscription "$SHARED_SUB" --query tags.createdBy -o tsv 2>/dev/null)" == "$PREFIX-test" ]] \
       && [[ "$(az resource list -g "$DNS_RG" --subscription "$SHARED_SUB" --query 'length(@)' -o tsv)" == 0 ]]; then
      az group delete -n "$DNS_RG" --subscription "$SHARED_SUB" --yes -o none && info "deleted  $DNS_RG"
    fi
  else
    info "zones in $DNS_RG kept (set PURGE_DNS=true to remove the ones this script created)"
  fi
  rm -rf "$STATE_DIR" && info "removed  $STATE_DIR (including the SPN secret)"
}

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- main
(( BASH_VERSINFO[0] >= 4 )) || die "bash >= 4 required (macOS: brew install bash), or use Azure Cloud Shell"
need az; need jq
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
case "${1:-}" in
  infra) cmd_infra ;;
  identity) cmd_identity ;;
  deploy) cmd_deploy ;;
  deny-test) cmd_deny_test ;;
  pe) cmd_pe ;;
  verify) cmd_verify ;;
  remediate) cmd_remediate ;;
  status) cmd_status ;;
  rbac-check) cmd_rbac_check ;;
  build) build_policy_json; info "files in $BUILD_DIR" ;;
  down) cmd_down ;;
  *) usage; exit 1 ;;
esac
