#!/usr/bin/env python3
"""Patch the generated Solr exporter settings for a non-TLS Solr deployment.

Privacera Manager 9.0.29.1 can generate an exporter command that connects to
the in-cluster Solr service with HTTPS even when that service is configured for
HTTP. It can also reference a truststore that is not generated or mounted in a
non-TLS deployment. Either mismatch makes the exporter exit during startup.
This patch is intentionally limited to the generated Solr exporter Deployment
template.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


HTTPS_SOLR_SERVICE = "https://solr-service."
HTTP_SOLR_SERVICE = "http://solr-service."
EXPORTER_NAME = "name: solr-exporter"
MISSING_TRUSTSTORE = "/etc/default/global-truststore.p12"
TRUSTSTORE_OPTIONS = re.compile(
    r"-Djavax\.net\.ssl\.trustStore=/etc/default/global-truststore\.p12\s+"
    r"-Djavax\.net\.ssl\.trustStorePassword=\S+\s*"
)


def patch_exporter(path: Path) -> bool:
    original = path.read_text(encoding="utf-8")
    if EXPORTER_NAME not in original:
        return False

    updated = original.replace(HTTPS_SOLR_SERVICE, HTTP_SOLR_SERVICE)
    updated = TRUSTSTORE_OPTIONS.sub("", updated)
    if HTTPS_SOLR_SERVICE in updated:
        raise SystemExit(f"HTTPS Solr service URL remains in {path}")
    if HTTP_SOLR_SERVICE not in updated:
        raise SystemExit(f"Solr service URL was not found in {path}")
    if MISSING_TRUSTSTORE in updated:
        raise SystemExit(f"Missing non-TLS truststore is still referenced in {path}")

    if updated == original:
        return False

    path.write_text(updated, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("charts_dir", type=Path)
    args = parser.parse_args()

    if not args.charts_dir.is_dir():
        parser.error(f"chart directory does not exist: {args.charts_dir}")

    candidates = sorted(
        path
        for pattern in ("*solr-exporter-deployment*.yaml", "*solr-exporter-deployment*.yml")
        for path in args.charts_dir.rglob(pattern)
        if path.is_file()
    )
    if not candidates:
        raise SystemExit("No generated Solr exporter Deployment template was found")

    patched = [path for path in candidates if patch_exporter(path)]
    print(f"Validated {len(candidates)} Solr exporter template(s); patched {len(patched)}")
    for path in patched:
        print(f"  - {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
