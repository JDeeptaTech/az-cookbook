'''

# Configuration Naming Standards

> `configurations` table · PostgreSQL · Platform Engineering · v1.0

---

## Rule

**Lowercase kebab-case everywhere.** No underscores, no camelCase, no mixed conventions.
Consistent with Kubernetes, Helm, ArgoCD, and the rest of the cloud-native tooling stack.

```
app_name    →  {domain}-{service}
config_name →  {concern}            (fixed vocabulary — see below)
environment →  dev | test | uat | prod
```

---

## `app_name`

Format: `{domain}-{service}`

The **domain** groups services by business or platform area.
The **service** is the specific application within that domain.

### Domain vocabulary

| Domain | Used for |
|--------|----------|
| `platform` | Internal developer platform services |
| `trading` | Algorithmic trading services |
| `azure` | Azure estate management services |
| `aap` | Ansible Automation Platform services |

### Examples

```
platform-config-api
platform-vm-provisioner
platform-placement-engine
platform-argocd-sync
platform-backstage

trading-engine
trading-data-feed
trading-order-manager

azure-subscription-sync
azure-cost-reporter
azure-policy-enforcer

aap-job-runner
aap-credential-manager
```

### Rules

- Lowercase only: `a-z`, `0-9`, `-`
- Must start with a letter
- No leading or trailing hyphens
- No underscores: `vm_provisioner` ✖ → `vm-provisioner` ✅
- No camelCase: `tradingEngine` ✖ → `trading-engine` ✅
- No vague names: `myapp`, `app1`, `service` ✖

---

## `config_name`

Fixed vocabulary — one row per concern per app/environment.

| config_name | Contains |
|-------------|----------|
| `database` | Primary DB — host, port, name, password 🔑 |
| `database-replica` | Read replica connection |
| `cache` | Redis / Memcached — host, port, TTL |
| `messaging` | Service Bus / RabbitMQ / Kafka |
| `storage` | Blob storage / S3 |
| `feature-flags` | Boolean toggles, rollout percentages |
| `integrations` | Third-party API connections — keys 🔑, base URLs |
| `observability` | Splunk, OpenTelemetry, log levels |
| `security` | TLS settings, allowed CIDRs, auth config |
| `scheduling` | Cron / RRULE schedules for AAP jobs |
| `limits` | Rate limits, timeouts, pool sizes, resource quotas |
| `notifications` | Email, Teams webhook, PagerDuty endpoints |

### Rules

- Use only the vocabulary above — do not invent new names without updating this doc and the DB constraint
- One row per concern — do not combine unrelated settings into one row
- Do not use a catch-all `default` or `general` — named groups are easier to own, audit, and rotate independently

---

## `environment`

Fixed four values only.

| Value | Used for |
|-------|----------|
| `dev` | Local / developer environment |
| `test` | Automated testing / CI |
| `uat` | User acceptance testing / pre-prod |
| `prod` | Production |

**Never use:** `production`, `Production`, `staging`, `preprod`, `sandbox`, `qa`

---

## Concrete examples

```
app_name                      config_name      environment
────────────────────────────  ───────────────  ───────────
platform-vm-provisioner       database         prod
platform-vm-provisioner       cache            prod
platform-vm-provisioner       integrations     prod        ← AAP, Vault, Insights 🔑
platform-vm-provisioner       feature-flags    prod
platform-vm-provisioner       limits           prod
platform-vm-provisioner       observability    prod

platform-config-api           database         prod
platform-config-api           security         prod
platform-config-api           observability    prod

platform-placement-engine     database         prod
platform-placement-engine     scheduling       prod
platform-placement-engine     limits           prod

trading-engine                database         prod
trading-engine                integrations     prod        ← IG Markets 🔑
trading-engine                feature-flags    prod
trading-engine                limits           prod

azure-subscription-sync       integrations     prod        ← ARM API, ADO 🔑
azure-subscription-sync       scheduling       prod
azure-subscription-sync       observability    prod

aap-job-runner                database         prod
aap-job-runner                integrations     prod        ← AAP API 🔑
aap-job-runner                scheduling       prod
```

---

## DB Constraints

Naming rules are enforced at the database level.
Nothing invalid can be inserted regardless of how the API or Ansible is called.

```sql
-- Environment must be one of the four allowed values
ALTER TABLE configurations
    ADD CONSTRAINT chk_environment
    CHECK (environment IN ('dev', 'test', 'uat', 'prod'));

-- app_name: lowercase kebab-case, 3–150 chars
ALTER TABLE configurations
    ADD CONSTRAINT chk_app_name_format
    CHECK (app_name ~ '^[a-z][a-z0-9-]{1,148}[a-z0-9]$');

-- config_name: lowercase kebab-case
ALTER TABLE configurations
    ADD CONSTRAINT chk_config_name_format
    CHECK (config_name ~ '^[a-z][a-z0-9-]{0,148}$');

-- config_name must be from the approved vocabulary
ALTER TABLE configurations
    ADD CONSTRAINT chk_config_name_vocab
    CHECK (config_name IN (
        'database',
        'database-replica',
        'cache',
        'messaging',
        'storage',
        'feature-flags',
        'integrations',
        'observability',
        'security',
        'scheduling',
        'limits',
        'notifications'
    ));
```

To add a new `config_name` to the vocabulary, update the constraint:

```sql
ALTER TABLE configurations DROP CONSTRAINT chk_config_name_vocab;

ALTER TABLE configurations
    ADD CONSTRAINT chk_config_name_vocab
    CHECK (config_name IN (
        'database',
        'database-replica',
        'cache',
        'messaging',
        'storage',
        'feature-flags',
        'integrations',
        'observability',
        'security',
        'scheduling',
        'limits',
        'notifications',
        'your-new-name'     -- ← add here
    ));
```

---

## Quick Reference

```
┌─────────────────────────────────────────────────────────────┐
│  configurations naming standard                             │
├──────────────┬──────────────────────────────────────────────┤
│  app_name    │  {domain}-{service}                          │
│              │  platform-vm-provisioner                     │
│              │  trading-engine                              │
│              │  azure-subscription-sync                     │
├──────────────┼──────────────────────────────────────────────┤
│  config_name │  fixed vocabulary — single concern per row   │
│              │  database         cache        messaging     │
│              │  feature-flags    integrations observability │
│              │  security         scheduling   limits        │
│              │  storage          notifications              │
├──────────────┼──────────────────────────────────────────────┤
│  environment │  dev | test | uat | prod  (only)             │
├──────────────┼──────────────────────────────────────────────┤
│  format      │  lowercase kebab-case everywhere             │
└──────────────┴──────────────────────────────────────────────┘
```

---

*Internal use only · Infrastructure & Platform Engineering · v1.0*
