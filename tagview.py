#!/usr/bin/env python3
"""tagview - list Azure resources grouped by environment tag.

Install:
    pip install click rich azure-identity azure-mgmt-resourcegraph

Examples:
    tagview.py                                      # every subscription you can read
    tagview.py -s <sub-id> --env prod --env staging
    tagview.py --type microsoft.compute/virtualmachines --summary
    tagview.py --tag team=platform -o json
    tagview.py --env-key stage --raw-env -o csv
"""
from __future__ import annotations

import csv
import json
import re
import sys
from collections import defaultdict
from dataclasses import asdict, dataclass, field
from typing import Callable, Iterable, Iterator

import click
from rich.console import Console
from rich.table import Table

UNTAGGED = "(untagged)"
DEFAULT_ENV_KEYS = ("environment", "env")

# Collapse the usual drift in env values. Extend to match your tagging policy.
ENV_ALIASES = {
    "prd": "prod", "production": "prod", "live": "prod",
    "stg": "staging", "stage": "staging",
    "tst": "test",
    "development": "dev", "devel": "dev",
}

_SAFE_TYPE = re.compile(r"^[A-Za-z0-9./-]+$")

out = Console()
err = Console(stderr=True)


@dataclass
class Resource:
    name: str
    type: str
    location: str
    subscription: str
    resource_group: str
    env: str
    tags: dict = field(default_factory=dict)


EnvResolver = Callable[[dict], str]


# --------------------------------------------------------------------------- #
# Tag handling
# --------------------------------------------------------------------------- #
def normalise_env(value: str, raw: bool) -> str:
    value = value.strip()
    if raw:
        return value
    value = value.lower()
    return ENV_ALIASES.get(value, value)


def make_env_resolver(keys: Iterable[str], raw: bool) -> EnvResolver:
    keys = [k.lower() for k in keys]

    def resolve(tags: dict) -> str:
        # Azure tag keys are case-insensitive, so Environment/environment/ENV are the same key.
        lowered = {k.lower(): v for k, v in (tags or {}).items()}
        for k in keys:
            v = lowered.get(k)
            if v and v.strip():
                return normalise_env(v, raw)
        return UNTAGGED

    return resolve


def parse_tag_filters(items: Iterable[str]) -> list[tuple[str, str]]:
    parsed = []
    for item in items:
        k, sep, v = item.partition("=")
        if not sep or not k:
            raise click.BadParameter(f"expected KEY=VALUE, got {item!r}", param_hint="--tag")
        parsed.append((k.lower(), v))
    return parsed


def tag_match(tags: dict, filters: list[tuple[str, str]]) -> bool:
    lowered = {k.lower(): v for k, v in (tags or {}).items()}
    for k, v in filters:
        if k not in lowered:
            return False
        if v != "*" and lowered[k].lower() != v.lower():
            return False
    return True


# --------------------------------------------------------------------------- #
# Azure Resource Graph
# --------------------------------------------------------------------------- #
def build_query(rtype: str | None) -> str:
    query = "Resources"
    if rtype:
        # Validate rather than escape: type names have a tiny alphabet, and this avoids KQL injection.
        if not _SAFE_TYPE.match(rtype):
            raise click.BadParameter(f"invalid resource type {rtype!r}", param_hint="--type")
        query += f" | where type =~ '{rtype}'"
    return query + " | project name, type, location, resourceGroup, subscriptionId, tags"


def azure_resources(subscriptions: tuple[str, ...], rtype: str | None,
                    env_of: EnvResolver) -> Iterator[Resource]:
    try:
        from azure.identity import DefaultAzureCredential
        from azure.mgmt.resourcegraph import ResourceGraphClient
        from azure.mgmt.resourcegraph.models import QueryRequest, QueryRequestOptions
    except ImportError:
        raise click.ClickException("pip install azure-identity azure-mgmt-resourcegraph")

    query = build_query(rtype)
    client = ResourceGraphClient(DefaultAzureCredential())
    token = None
    while True:
        resp = client.resources(QueryRequest(
            subscriptions=list(subscriptions) or None,  # None = all subs the identity can read
            query=query,
            options=QueryRequestOptions(result_format="objectArray", top=1000, skip_token=token),
        ))
        for row in resp.data:
            tags = row.get("tags") or {}
            yield Resource(
                name=row["name"],
                type=row["type"],
                location=row.get("location") or "",
                subscription=row["subscriptionId"],
                resource_group=row.get("resourceGroup") or "",
                env=env_of(tags),
                tags=tags,
            )
        token = resp.skip_token
        if not token:
            break


# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #
def group_by_env(resources: Iterable[Resource]) -> dict[str, list[Resource]]:
    groups: dict[str, list[Resource]] = defaultdict(list)
    for r in resources:
        groups[r.env].append(r)
    ordered = sorted(groups, key=lambda e: (e == UNTAGGED, e))  # untagged last
    return {e: sorted(groups[e], key=lambda r: (r.type, r.name)) for e in ordered}


def render(groups: dict[str, list[Resource]], output: str, summary: bool) -> None:
    if output == "json":
        payload = ({e: len(rs) for e, rs in groups.items()} if summary
                   else {e: [asdict(r) for r in rs] for e, rs in groups.items()})
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return

    if output == "csv":
        w = csv.writer(sys.stdout)
        if summary:
            w.writerow(["env", "count"])
            w.writerows((e, len(rs)) for e, rs in groups.items())
        else:
            w.writerow(["env", "name", "type", "subscription", "resource_group", "location", "tags"])
            for e, rs in groups.items():
                for r in rs:
                    w.writerow([e, r.name, r.type, r.subscription, r.resource_group, r.location,
                                json.dumps(r.tags, sort_keys=True)])
        return

    if not summary:
        for env, rs in groups.items():
            t = Table(title=f"{env}  ({len(rs)})", title_justify="left",
                      title_style="bold magenta" if env != UNTAGGED else "bold red")
            for col in ("Name", "Type", "Resource group", "Location"):
                t.add_column(col, overflow="fold")
            for r in rs:
                t.add_row(r.name, r.type, r.resource_group, r.location)
            out.print(t)

    s = Table(title="Summary", title_justify="left")
    s.add_column("Environment")
    s.add_column("Resources", justify="right")
    for env, rs in groups.items():
        s.add_row(f"[red]{env}[/]" if env == UNTAGGED else env, str(len(rs)))
    s.add_row("[bold]total[/]", f"[bold]{sum(len(rs) for rs in groups.values())}[/]")
    out.print(s)


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
@click.command()
@click.option("-s", "--subscription", "subscriptions", multiple=True,
              help="Subscription ID (repeatable). Default: all readable subscriptions.")
@click.option("--env-key", "env_keys", multiple=True, default=DEFAULT_ENV_KEYS, show_default=True,
              help="Tag keys holding the environment, in priority order.")
@click.option("--env", "envs", multiple=True,
              help="Only these environments (repeatable). Use '(untagged)' for missing.")
@click.option("--tag", "tags", multiple=True, metavar="KEY=VALUE",
              help="Extra tag filter, repeatable, ANDed. VALUE '*' = key exists.")
@click.option("--type", "rtype", help="Resource type, e.g. microsoft.compute/virtualmachines.")
@click.option("--raw-env", is_flag=True, help="Don't normalise env values (prd -> prod).")
@click.option("-o", "--output", type=click.Choice(["table", "json", "csv"]),
              default="table", show_default=True)
@click.option("--summary", is_flag=True, help="Only show counts per environment.")
def cli(subscriptions, env_keys, envs, tags, rtype, raw_env, output, summary):
    """List Azure resources grouped by environment tag (via Resource Graph)."""
    env_of = make_env_resolver(env_keys, raw_env)
    tag_filters = parse_tag_filters(tags)
    wanted = {e if e == UNTAGGED else normalise_env(e, raw_env) for e in envs}

    selected = (
        r for r in azure_resources(subscriptions, rtype, env_of)
        if (not wanted or r.env in wanted) and (not tag_filters or tag_match(r.tags, tag_filters))
    )
    if output == "table":
        with err.status("Querying Azure Resource Graph..."):
            groups = group_by_env(selected)
    else:
        groups = group_by_env(selected)

    if not groups:
        err.print("[yellow]No resources matched.[/]")
        return
    render(groups, output, summary)


if __name__ == "__main__":
    try:
        cli()
    except KeyboardInterrupt:
        sys.exit(130)
