#!/usr/bin/env python3
"""
Sync VM telemetry from Kafka into PostgreSQL.

Topics (OTLP from the central gateway, or plain JSON from the capacity poller):
  logs topic     -> k8s_objects records for VirtualMachine / VirtualMachineInstance
                    => vm_inventory, vmi_state, vm_events
  metrics topic  -> OTLP metrics (kubevirt_vmi_*, capacity) => metric_samples

Delivery: Kafka offsets are stored in Postgres in the same transaction as the data,
so a crash or rebalance never double-applies or skips a message. Writes are also
idempotent (resourceVersion guards, ON CONFLICT), so replays are harmless.

Env:
  KAFKA_BOOTSTRAP, KAFKA_GROUP (default vm-sync)
  KAFKA_SECURITY_PROTOCOL (SSL), KAFKA_CA, KAFKA_CERT, KAFKA_KEY
  TOPIC_LOGS (default eosvmaudit.logs.raw), TOPIC_METRICS (default vm-metrics; empty to disable)
  PAYLOAD_ENCODING otlp_json | otlp_proto (default otlp_json)
  PG_DSN  e.g. "host=pg dbname=vmtel user=vm_sync sslmode=verify-full"  (password via PGPASSWORD)
  DEFAULT_CLUSTER  used when records carry no cluster attribute
  METRIC_PREFIXES  comma list (default kubevirt_vmi_,vm_memory_)
  BATCH_SIZE (500), METRIC_RETENTION_DAYS (30), EVENT_RETENTION_DAYS (180)
"""
from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import signal
import sys
import time
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from typing import Any, Iterable

import psycopg
from psycopg.types.json import Jsonb
from confluent_kafka import Consumer, KafkaError, TopicPartition

log = logging.getLogger("vm_sync")

# --------------------------------------------------------------------------- config

@dataclass(frozen=True)
class Config:
    bootstrap: str = os.environ.get("KAFKA_BOOTSTRAP", "localhost:9092")
    group: str = os.environ.get("KAFKA_GROUP", "vm-sync")
    security_protocol: str = os.environ.get("KAFKA_SECURITY_PROTOCOL", "PLAINTEXT")
    ca: str | None = os.environ.get("KAFKA_CA")
    cert: str | None = os.environ.get("KAFKA_CERT")
    key: str | None = os.environ.get("KAFKA_KEY")
    topic_logs: str = os.environ.get("TOPIC_LOGS", "eosvmaudit.logs.raw")
    topic_metrics: str = os.environ.get("TOPIC_METRICS", "vm-metrics")
    encoding: str = os.environ.get("PAYLOAD_ENCODING", "otlp_json")
    pg_dsn: str = os.environ.get("PG_DSN", "dbname=vmtel")
    default_cluster: str = os.environ.get("DEFAULT_CLUSTER", "unknown")
    metric_prefixes: tuple[str, ...] = tuple(
        p.strip() for p in os.environ.get("METRIC_PREFIXES", "kubevirt_vmi_,vm_memory_").split(",") if p.strip())
    batch_size: int = int(os.environ.get("BATCH_SIZE", "500"))
    metric_retention_days: int = int(os.environ.get("METRIC_RETENTION_DAYS", "30"))
    event_retention_days: int = int(os.environ.get("EVENT_RETENTION_DAYS", "180"))

    @property
    def topics(self) -> list[str]:
        return [t for t in (self.topic_logs, self.topic_metrics) if t]


# --------------------------------------------------------------------------- decoding

def decode_payload(raw: bytes, encoding: str) -> dict:
    """Return the OTLP export request (or poller record) as a JSON-shaped dict."""
    if encoding == "otlp_proto":
        # Lazy import: only needed for proto payloads.
        from google.protobuf.json_format import MessageToDict
        from opentelemetry.proto.collector.logs.v1.logs_service_pb2 import ExportLogsServiceRequest
        from opentelemetry.proto.collector.metrics.v1.metrics_service_pb2 import ExportMetricsServiceRequest
        for cls in (ExportLogsServiceRequest, ExportMetricsServiceRequest):
            msg = cls()
            try:
                msg.ParseFromString(raw)
            except Exception:
                continue
            d = MessageToDict(msg)
            if d.get("resourceLogs") or d.get("resourceMetrics"):
                return d
        raise ValueError("payload is not an OTLP logs or metrics request")
    return json.loads(raw)


def any_value(v: dict | None) -> Any:
    """OTLP AnyValue (JSON mapping) -> native Python."""
    if not v:
        return None
    if "stringValue" in v:
        return v["stringValue"]
    if "boolValue" in v:
        return v["boolValue"]
    if "intValue" in v:
        return int(v["intValue"])          # int64 is a string in OTLP/JSON
    if "doubleValue" in v:
        return float(v["doubleValue"])
    if "bytesValue" in v:
        return base64.b64decode(v["bytesValue"])
    if "arrayValue" in v:
        return [any_value(x) for x in v["arrayValue"].get("values", [])]
    if "kvlistValue" in v:
        return {kv["key"]: any_value(kv.get("value")) for kv in v["kvlistValue"].get("values", [])}
    return None


def attrs(kvs: Iterable[dict] | None) -> dict:
    return {kv["key"]: any_value(kv.get("value")) for kv in (kvs or [])}


def ns_to_dt(ns: str | int | None) -> datetime | None:
    if not ns or int(ns) == 0:
        return None
    return datetime.fromtimestamp(int(ns) / 1e9, tz=timezone.utc)


def parse_k8s_time(s: str | None) -> datetime | None:
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def cluster_of(res: dict, default: str) -> str:
    return str(res.get("k8s.cluster.name") or res.get("cluster") or default)


# --------------------------------------------------------------------------- domain records

@dataclass
class ObjRecord:
    cluster: str
    event_type: str              # ADDED | MODIFIED | DELETED | SNAPSHOT
    observed_at: datetime
    obj: dict

    @property
    def kind(self) -> str:
        return self.obj.get("kind", "")

    @property
    def meta(self) -> dict:
        return self.obj.get("metadata") or {}

    @property
    def resource_version(self) -> int:
        rv = self.meta.get("resourceVersion")
        try:
            return int(rv)
        except (TypeError, ValueError):
            raise ValueError(f"non-numeric resourceVersion {rv!r}") from None


@dataclass
class Sample:
    ts: datetime
    cluster: str
    metric: str
    attributes: dict = field(default_factory=dict)
    value: float = 0.0

    @property
    def series_hash(self) -> int:
        key = self.cluster + "\x00" + self.metric + "\x00" + json.dumps(self.attributes, sort_keys=True, default=str)
        return int.from_bytes(hashlib.blake2b(key.encode(), digest_size=8).digest(), "big", signed=True)


def extract_objects(payload: dict, default_cluster: str) -> list[ObjRecord]:
    out: list[ObjRecord] = []
    for rl in payload.get("resourceLogs", []):
        cluster = cluster_of(attrs(rl.get("resource", {}).get("attributes")), default_cluster)
        for sl in rl.get("scopeLogs", []):
            for lr in sl.get("logRecords", []):
                body = any_value(lr.get("body"))
                if isinstance(body, str):          # some pipelines stringify the body
                    body = json.loads(body)
                if not isinstance(body, dict):
                    continue
                if "object" in body and "type" in body:      # watch mode
                    obj, etype = body["object"], str(body["type"]).upper()
                else:                                         # pull mode
                    obj, etype = body, "SNAPSHOT"
                if obj.get("kind") not in ("VirtualMachine", "VirtualMachineInstance"):
                    continue
                ts = (ns_to_dt(lr.get("timeUnixNano")) or ns_to_dt(lr.get("observedTimeUnixNano"))
                      or datetime.now(timezone.utc))
                out.append(ObjRecord(cluster, etype, ts, obj))
    return out


def extract_samples(payload: dict, default_cluster: str, prefixes: tuple[str, ...]) -> list[Sample]:
    # Plain JSON from the capacity poller
    if "metric" in payload and "value" in payload:
        return [Sample(
            ts=datetime.fromtimestamp(float(payload["timestamp"]), tz=timezone.utc),
            cluster=payload.get("cluster") or default_cluster,
            metric=payload["metric"],
            attributes=payload.get("labels") or {},
            value=float(payload["value"]),
        )]
    out: list[Sample] = []
    for rm in payload.get("resourceMetrics", []):
        res = attrs(rm.get("resource", {}).get("attributes"))
        cluster = cluster_of(res, default_cluster)
        for sm in rm.get("scopeMetrics", []):
            for m in sm.get("metrics", []):
                name = m.get("name", "")
                if prefixes and not name.startswith(prefixes):
                    continue
                points = (m.get("gauge") or m.get("sum") or {}).get("dataPoints", [])
                for dp in points:            # histograms/summaries deliberately skipped
                    if "asDouble" in dp:
                        val = float(dp["asDouble"])
                    elif "asInt" in dp:
                        val = float(int(dp["asInt"]))
                    else:
                        continue
                    if dp.get("flags", 0) & 1:   # NO_RECORDED_VALUE (staleness marker)
                        continue
                    a = {k: v for k, v in res.items() if k.startswith("k8s.")}
                    a.update(attrs(dp.get("attributes")))
                    out.append(Sample(ns_to_dt(dp.get("timeUnixNano")) or datetime.now(timezone.utc),
                                      cluster, name, a, val))
    return out


# --------------------------------------------------------------------------- SQL

UPSERT_VM = """
INSERT INTO vmtel.vm_inventory AS t (
    uid, cluster, namespace, name, run_strategy, printable_status, ready, cpu_cores,
    memory_request, instancetype, labels, annotations, created_at, resource_version,
    deleted_at, last_seen_at, object)
VALUES (%(uid)s, %(cluster)s, %(namespace)s, %(name)s, %(run_strategy)s, %(printable_status)s,
        %(ready)s, %(cpu_cores)s, %(memory_request)s, %(instancetype)s, %(labels)s, %(annotations)s,
        %(created_at)s, %(rv)s, %(deleted_at)s, %(seen)s, %(object)s)
ON CONFLICT (uid) DO UPDATE SET
    run_strategy = EXCLUDED.run_strategy, printable_status = EXCLUDED.printable_status,
    ready = EXCLUDED.ready, cpu_cores = EXCLUDED.cpu_cores, memory_request = EXCLUDED.memory_request,
    instancetype = EXCLUDED.instancetype, labels = EXCLUDED.labels, annotations = EXCLUDED.annotations,
    resource_version = EXCLUDED.resource_version,
    deleted_at = COALESCE(EXCLUDED.deleted_at, t.deleted_at),
    last_seen_at = EXCLUDED.last_seen_at, object = EXCLUDED.object
WHERE t.resource_version < EXCLUDED.resource_version
   OR (t.resource_version = EXCLUDED.resource_version AND EXCLUDED.deleted_at IS NOT NULL AND t.deleted_at IS NULL)
RETURNING uid
"""

TOUCH_SEEN = "UPDATE vmtel.{table} SET last_seen_at = GREATEST(last_seen_at, %s) WHERE uid = %s"

UPSERT_VMI = """
INSERT INTO vmtel.vmi_state AS t (
    uid, cluster, namespace, name, vm_uid, node, phase, ip_addresses, migration_state,
    resource_version, deleted_at, last_seen_at)
VALUES (%(uid)s, %(cluster)s, %(namespace)s, %(name)s, %(vm_uid)s, %(node)s, %(phase)s,
        %(ips)s, %(migration)s, %(rv)s, %(deleted_at)s, %(seen)s)
ON CONFLICT (uid) DO UPDATE SET
    vm_uid = EXCLUDED.vm_uid, node = EXCLUDED.node, phase = EXCLUDED.phase,
    ip_addresses = EXCLUDED.ip_addresses, migration_state = EXCLUDED.migration_state,
    resource_version = EXCLUDED.resource_version,
    deleted_at = COALESCE(EXCLUDED.deleted_at, t.deleted_at),
    last_seen_at = EXCLUDED.last_seen_at
WHERE t.resource_version < EXCLUDED.resource_version
   OR (t.resource_version = EXCLUDED.resource_version AND EXCLUDED.deleted_at IS NOT NULL AND t.deleted_at IS NULL)
RETURNING uid
"""

INSERT_EVENT = """
INSERT INTO vmtel.vm_events (cluster, kind, uid, namespace, name, event_type, resource_version, observed_at, status)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT DO NOTHING
"""

UPSERT_OFFSET = """
INSERT INTO vmtel.kafka_offsets (consumer_group, topic, partition, next_offset, updated_at)
VALUES (%s, %s, %s, %s, now())
ON CONFLICT (consumer_group, topic, partition)
DO UPDATE SET next_offset = EXCLUDED.next_offset, updated_at = now()
"""

INSERT_DLQ = """
INSERT INTO vmtel.dead_letters (topic, partition, "offset", error, payload)
VALUES (%s, %s, %s, %s, %s) ON CONFLICT DO NOTHING
"""


# --------------------------------------------------------------------------- writers

def vm_row(r: ObjRecord) -> dict:
    spec = r.obj.get("spec") or {}
    status = r.obj.get("status") or {}
    dom = ((spec.get("template") or {}).get("spec") or {}).get("domain") or {}
    run_strategy = spec.get("runStrategy") or (
        None if spec.get("running") is None else ("Always" if spec["running"] else "Halted"))
    return {
        "uid": r.meta["uid"], "cluster": r.cluster,
        "namespace": r.meta.get("namespace", ""), "name": r.meta.get("name", ""),
        "run_strategy": run_strategy,
        "printable_status": status.get("printableStatus"),
        "ready": status.get("ready"),
        "cpu_cores": (dom.get("cpu") or {}).get("cores"),
        "memory_request": ((dom.get("resources") or {}).get("requests") or {}).get("memory")
                          or (dom.get("memory") or {}).get("guest"),
        "instancetype": (spec.get("instancetype") or {}).get("name"),
        "labels": Jsonb(r.meta.get("labels") or {}),
        "annotations": Jsonb(r.meta.get("annotations") or {}),
        "created_at": parse_k8s_time(r.meta.get("creationTimestamp")),
        "rv": r.resource_version,
        "deleted_at": r.observed_at if r.event_type == "DELETED" else None,
        "seen": r.observed_at,
        "object": Jsonb(r.obj),
    }


def vmi_row(r: ObjRecord) -> dict:
    status = r.obj.get("status") or {}
    owner = next((o for o in r.meta.get("ownerReferences") or [] if o.get("kind") == "VirtualMachine"), None)
    ips = sorted({ip for i in status.get("interfaces") or []
                  for ip in (i.get("ipAddresses") or ([i["ipAddress"]] if i.get("ipAddress") else []))})
    return {
        "uid": r.meta["uid"], "cluster": r.cluster,
        "namespace": r.meta.get("namespace", ""), "name": r.meta.get("name", ""),
        "vm_uid": owner.get("uid") if owner else None,
        "node": status.get("nodeName"), "phase": status.get("phase"),
        "ips": ips or None,
        "migration": Jsonb(status["migrationState"]) if status.get("migrationState") else None,
        "rv": r.resource_version,
        "deleted_at": r.observed_at if r.event_type == "DELETED" else None,
        "seen": r.observed_at,
    }


def apply_objects(cur: psycopg.Cursor, records: list[ObjRecord]) -> None:
    for r in records:
        if r.kind == "VirtualMachine":
            sql, row, table = UPSERT_VM, vm_row(r), "vm_inventory"
        else:
            sql, row, table = UPSERT_VMI, vmi_row(r), "vmi_state"
        cur.execute(sql, row)
        changed = cur.fetchone() is not None
        if not changed:
            # Stale or duplicate (e.g. a 15m pull of an unchanged VM): only refresh last_seen.
            cur.execute(TOUCH_SEEN.format(table=table), (r.observed_at, row["uid"]))
        # Watch events are history; snapshots only count when they reveal a missed change.
        if r.event_type != "SNAPSHOT" or changed:
            cur.execute(INSERT_EVENT, (
                r.cluster, r.kind, row["uid"], row["namespace"], row["name"], r.event_type,
                row["rv"], r.observed_at, Jsonb(r.obj.get("status") or {})))


def apply_samples(cur: psycopg.Cursor, samples: list[Sample]) -> None:
    if not samples:
        return
    # COPY into a temp table, then one INSERT ... ON CONFLICT: far faster than executemany.
    cur.execute("""CREATE TEMP TABLE IF NOT EXISTS tmp_samples
                   (LIKE vmtel.metric_samples INCLUDING DEFAULTS) ON COMMIT DELETE ROWS""")
    with cur.copy("COPY tmp_samples (ts, cluster, metric, namespace, vm_name, series_hash, attributes, value) "
                  "FROM STDIN") as cp:
        for s in samples:
            cp.write_row((s.ts, s.cluster, s.metric,
                          s.attributes.get("namespace") or s.attributes.get("k8s.namespace.name"),
                          s.attributes.get("name"),
                          s.series_hash, json.dumps(s.attributes, default=str), s.value))
    cur.execute("INSERT INTO vmtel.metric_samples SELECT * FROM tmp_samples ON CONFLICT DO NOTHING")


# --------------------------------------------------------------------------- partitions

def ensure_partitions(conn: psycopg.Connection, cfg: Config) -> None:
    """Create daily partitions for yesterday..today+3 and drop expired ones."""
    today = date.today()
    for table, retention in (("vm_events", cfg.event_retention_days),
                             ("metric_samples", cfg.metric_retention_days)):
        for d in (today + timedelta(days=i) for i in range(-1, 4)):
            part = f"{table}_{d:%Y%m%d}"
            try:
                with conn.transaction():
                    conn.execute(
                        f"CREATE TABLE IF NOT EXISTS vmtel.{part} PARTITION OF vmtel.{table} "
                        f"FOR VALUES FROM ('{d}') TO ('{d + timedelta(days=1)}')")
            except psycopg.Error as e:
                # Usually rows for this day already sit in the default partition.
                log.warning("could not create partition %s: %s", part, e)
        cutoff = today - timedelta(days=retention)
        rows = conn.execute(
            "SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid "
            "JOIN pg_class p ON p.oid = i.inhparent JOIN pg_namespace n ON n.oid = p.relnamespace "
            "WHERE n.nspname = 'vmtel' AND p.relname = %s AND c.relname ~ %s",
            (table, rf"^{table}_\d{{8}}$")).fetchall()
        for (relname,) in rows:
            if datetime.strptime(relname[-8:], "%Y%m%d").date() < cutoff:
                with conn.transaction():
                    conn.execute(f"DROP TABLE IF EXISTS vmtel.{relname}")
                log.info("dropped expired partition %s", relname)


# --------------------------------------------------------------------------- main loop

class Sync:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.running = True
        self.conn = psycopg.connect(cfg.pg_dsn, autocommit=True, application_name="vm-sync")
        kconf = {
            "bootstrap.servers": cfg.bootstrap,
            "group.id": cfg.group,
            "enable.auto.commit": False,          # Postgres is the source of truth for offsets
            "enable.auto.offset.store": False,
            "auto.offset.reset": "earliest",
            "security.protocol": cfg.security_protocol,
            "max.poll.interval.ms": 300000,
            "client.id": f"vm-sync-{os.environ.get('HOSTNAME', 'local')}",
        }
        if cfg.ca:
            kconf["ssl.ca.location"] = cfg.ca
        if cfg.cert and cfg.key:
            kconf.update({"ssl.certificate.location": cfg.cert, "ssl.key.location": cfg.key})
        self.consumer = Consumer(kconf)

    # Seek every newly assigned partition to the offset stored in Postgres.
    def _on_assign(self, consumer: Consumer, partitions: list[TopicPartition]) -> None:
        rows = self.conn.execute(
            "SELECT topic, partition, next_offset FROM vmtel.kafka_offsets "
            "WHERE consumer_group = %s AND topic = ANY(%s)",
            (self.cfg.group, list({p.topic for p in partitions}))).fetchall()
        stored = {(t, p): o for t, p, o in rows}
        for p in partitions:
            if (p.topic, p.partition) in stored:
                p.offset = stored[(p.topic, p.partition)]
        log.info("assigned %s", [(p.topic, p.partition, p.offset) for p in partitions])
        consumer.assign(partitions)

    def _on_revoke(self, consumer: Consumer, partitions: list[TopicPartition]) -> None:
        log.info("revoked %s", [(p.topic, p.partition) for p in partitions])

    def stop(self, *_):
        log.info("shutdown requested")
        self.running = False

    def process_batch(self, msgs) -> None:
        next_offsets: dict[tuple[str, int], int] = {}
        n_obj = n_samples = n_dlq = 0
        with self.conn.transaction(), self.conn.cursor() as cur:
            for m in msgs:
                tp = (m.topic(), m.partition())
                next_offsets[tp] = max(next_offsets.get(tp, -1), m.offset() + 1)
                if m.value() is None:
                    continue
                try:
                    with self.conn.transaction():              # savepoint per message
                        payload = decode_payload(m.value(), self.cfg.encoding)
                        if m.topic() == self.cfg.topic_logs:
                            recs = extract_objects(payload, self.cfg.default_cluster)
                            apply_objects(cur, recs)
                            n_obj += len(recs)
                        else:
                            s = extract_samples(payload, self.cfg.default_cluster, self.cfg.metric_prefixes)
                            apply_samples(cur, s)
                            n_samples += len(s)
                except (ValueError, KeyError, TypeError, psycopg.DataError) as e:
                    # Bad payload: park it, keep going. Connection errors are NOT caught here.
                    n_dlq += 1
                    log.warning("dead-letter %s[%d]@%d: %s", *tp, m.offset(), e)
                    cur.execute(INSERT_DLQ, (*tp, m.offset(), f"{type(e).__name__}: {e}"[:2000], m.value()))
            for (topic, part), off in next_offsets.items():
                cur.execute(UPSERT_OFFSET, (self.cfg.group, topic, part, off))
        # Data and offsets are durable in PG. Mirror to Kafka for lag dashboards only.
        try:
            self.consumer.commit(offsets=[TopicPartition(t, p, o) for (t, p), o in next_offsets.items()],
                                 asynchronous=True)
        except Exception as e:  # noqa: BLE001 - lag reporting must never break the loop
            log.debug("kafka commit mirror failed: %s", e)
        log.info("batch: %d msgs, %d objects, %d samples, %d dead-lettered",
                 len(msgs), n_obj, n_samples, n_dlq)

    def run(self) -> None:
        signal.signal(signal.SIGTERM, self.stop)
        signal.signal(signal.SIGINT, self.stop)
        ensure_partitions(self.conn, self.cfg)
        last_maint = time.monotonic()
        self.consumer.subscribe(self.cfg.topics, on_assign=self._on_assign, on_revoke=self._on_revoke)
        try:
            while self.running:
                msgs = self.consumer.consume(num_messages=self.cfg.batch_size, timeout=1.0)
                good = []
                for m in msgs:
                    if m.error():
                        if m.error().code() != KafkaError._PARTITION_EOF:
                            log.error("kafka error: %s", m.error())
                        continue
                    good.append(m)
                if good:
                    self.process_batch(good)
                if time.monotonic() - last_maint > 3600:
                    ensure_partitions(self.conn, self.cfg)
                    last_maint = time.monotonic()
                with open("/tmp/vm-sync-alive", "w") as f:      # liveness probe target
                    f.write(str(time.time()))
        finally:
            self.consumer.close()
            self.conn.close()


def main() -> int:
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    cfg = Config()
    if cfg.encoding not in ("otlp_json", "otlp_proto"):
        log.error("PAYLOAD_ENCODING must be otlp_json or otlp_proto")
        return 2
    with psycopg.connect(cfg.pg_dsn, autocommit=True) as c:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema.sql")) as f:
            c.execute(f.read())
    # Any DB/Kafka connectivity failure propagates and exits non-zero: Kubernetes restarts
    # the pod and it resumes from the offsets stored in Postgres.
    Sync(cfg).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
