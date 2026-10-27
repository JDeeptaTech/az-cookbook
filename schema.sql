-- VM telemetry sink schema. Idempotent: safe to run on every deploy.
CREATE SCHEMA IF NOT EXISTS vmtel;
SET search_path = vmtel;

-- Kafka offsets committed in the same transaction as the data (exactly-once into PG)
CREATE TABLE IF NOT EXISTS kafka_offsets (
    consumer_group text   NOT NULL,
    topic          text   NOT NULL,
    partition      int    NOT NULL,
    next_offset    bigint NOT NULL,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (consumer_group, topic, partition)
);

-- Current state, one row per VirtualMachine
CREATE TABLE IF NOT EXISTS vm_inventory (
    uid              uuid PRIMARY KEY,
    cluster          text NOT NULL,
    namespace        text NOT NULL,
    name             text NOT NULL,
    run_strategy     text,
    printable_status text,
    ready            boolean,
    cpu_cores        int,
    memory_request   text,
    instancetype     text,
    labels           jsonb NOT NULL DEFAULT '{}',
    annotations      jsonb NOT NULL DEFAULT '{}',
    created_at       timestamptz,
    resource_version bigint NOT NULL,
    deleted_at       timestamptz,
    last_seen_at     timestamptz NOT NULL,
    object           jsonb NOT NULL
);
CREATE INDEX IF NOT EXISTS vm_inventory_ns_name ON vm_inventory (cluster, namespace, name);
CREATE INDEX IF NOT EXISTS vm_inventory_live    ON vm_inventory (cluster) WHERE deleted_at IS NULL;

-- Runtime state, one row per VirtualMachineInstance
CREATE TABLE IF NOT EXISTS vmi_state (
    uid              uuid PRIMARY KEY,
    cluster          text NOT NULL,
    namespace        text NOT NULL,
    name             text NOT NULL,
    vm_uid           uuid,
    node             text,
    phase            text,
    ip_addresses     text[],
    migration_state  jsonb,
    resource_version bigint NOT NULL,
    deleted_at       timestamptz,
    last_seen_at     timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS vmi_state_node ON vmi_state (cluster, node) WHERE deleted_at IS NULL;

-- Append-only change history (watch events + pull snapshots), deduplicated
CREATE TABLE IF NOT EXISTS vm_events (
    id               bigserial,
    cluster          text NOT NULL,
    kind             text NOT NULL,          -- VirtualMachine | VirtualMachineInstance
    uid              uuid NOT NULL,
    namespace        text NOT NULL,
    name             text NOT NULL,
    event_type       text NOT NULL,          -- ADDED | MODIFIED | DELETED | SNAPSHOT
    resource_version bigint NOT NULL,
    observed_at      timestamptz NOT NULL,
    status           jsonb,
    PRIMARY KEY (id, observed_at),
    UNIQUE (uid, resource_version, event_type, observed_at)
) PARTITION BY RANGE (observed_at);

-- Metric samples (kubevirt_vmi_* and capacity queries)
CREATE TABLE IF NOT EXISTS metric_samples (
    ts          timestamptz NOT NULL,
    cluster     text NOT NULL,
    metric      text NOT NULL,
    namespace   text,
    vm_name     text,
    series_hash bigint NOT NULL,             -- hash of metric + sorted attributes
    attributes  jsonb NOT NULL DEFAULT '{}',
    value       double precision NOT NULL,
    PRIMARY KEY (metric, series_hash, ts)
) PARTITION BY RANGE (ts);
CREATE INDEX IF NOT EXISTS metric_samples_vm ON metric_samples (cluster, namespace, vm_name, metric, ts DESC);

-- Messages that could not be parsed or applied
CREATE TABLE IF NOT EXISTS dead_letters (
    id         bigserial PRIMARY KEY,
    topic      text NOT NULL,
    partition  int NOT NULL,
    "offset"   bigint NOT NULL,
    error      text NOT NULL,
    payload    bytea,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (topic, partition, "offset")
);

-- Daily partitions are created by the consumer (ensure_partitions). A default
-- partition catches late or clock-skewed data so inserts never fail.
CREATE TABLE IF NOT EXISTS vm_events_default      PARTITION OF vm_events      DEFAULT;
CREATE TABLE IF NOT EXISTS metric_samples_default PARTITION OF metric_samples DEFAULT;
