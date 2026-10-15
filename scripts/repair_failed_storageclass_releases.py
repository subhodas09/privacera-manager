#!/usr/bin/env python3
"""Repair the one-time Helm migration from legacy AWS EBS StorageClasses.

The original Privacera releases stored gp2/in-tree StorageClass manifests in
Helm history. Kubernetes rejects an ordinary upgrade to the EBS CSI/gp3
manifests because StorageClass parameters are immutable. Only releases failed
for that exact reason are retried with Helm's replacement strategy.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path


CHART_BY_RELEASE = {
    "mariadb": "mariadb",
    "monitoring": "monitoring",
    "snowflake-test": "connector/snowflake/test",
    "privacera-diagnostics": "privacera-diagnostics",
    "zookeeper": "zookeeper",
    "solr": "solr",
    "auditserver": "auditserver",
}


def run(*args: str, capture: bool = False) -> str:
    result = subprocess.run(
        args,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
    )
    return result.stdout.strip() if capture else ""


def failed_releases(namespace: str) -> list[str]:
    output = run(
        "helm", "list", "--namespace", namespace, "--failed", "--short", capture=True
    )
    return [line for line in output.splitlines() if line]


def failure_description(release: str, namespace: str) -> str:
    status = run(
        "helm", "status", release, "--namespace", namespace, "--output", "json",
        capture=True,
    )
    return json.loads(status).get("info", {}).get("description", "")


def is_storageclass_immutability_error(description: str) -> bool:
    return (
        "cannot patch" in description
        and "StorageClass" in description
        and "updates to parameters are forbidden" in description
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("charts_dir", type=Path)
    parser.add_argument("namespace")
    args = parser.parse_args()

    failures = failed_releases(args.namespace)
    if not failures:
        print("No failed Helm releases require repair")
        return 0

    unexpected: list[str] = []
    for release in failures:
        description = failure_description(release, args.namespace)
        relative_chart = CHART_BY_RELEASE.get(release)
        if relative_chart is None or not is_storageclass_immutability_error(description):
            unexpected.append(f"{release}: {description}")
            continue

        chart = args.charts_dir / relative_chart
        if not (chart / "Chart.yaml").is_file():
            raise SystemExit(f"Generated chart not found for {release}: {chart}")

        print(f"Repairing {release} after immutable StorageClass migration")
        run(
            "helm", "upgrade", "--install", "--force", release, str(chart),
            "--namespace", args.namespace,
        )

    if unexpected:
        details = "\n".join(f"  - {item}" for item in unexpected)
        raise SystemExit(f"Unexpected failed Helm release(s):\n{details}")

    remaining = failed_releases(args.namespace)
    if remaining:
        names = ", ".join(remaining)
        raise SystemExit(f"Helm release repair did not succeed: {names}")

    print("All Helm releases are healthy after StorageClass migration repair")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
