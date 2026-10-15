#!/usr/bin/env python3
"""Patch generated Privacera StorageClasses for modern EKS/EBS CSI.

Privacera 7.0.0 emits the removed in-tree AWS EBS provisioner and uses
Immediate volume binding. On a multi-AZ EKS node group that can provision all
volumes in one Availability Zone before the scheduler chooses a node. This
patch is intentionally limited to generated StorageClass template files.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


LEGACY_PROVISIONER = "kubernetes.io/aws-ebs"
CSI_PROVISIONER = "ebs.csi.aws.com"


def patch_storage_class(path: Path) -> bool:
    original = path.read_text(encoding="utf-8")
    if "kind: StorageClass" not in original or LEGACY_PROVISIONER not in original:
        return False

    updated = re.sub(
        rf"(?m)^(?P<indent>\s*)provisioner:\s*{re.escape(LEGACY_PROVISIONER)}\s*$",
        rf"\g<indent>provisioner: {CSI_PROVISIONER}",
        original,
    )

    updated, binding_replacements = re.subn(
        r"(?m)^(?P<indent>\s*)#\s*volumeBindingMode:\s*WaitForFirstConsumer\s*$",
        r"\g<indent>volumeBindingMode: WaitForFirstConsumer",
        updated,
    )
    if binding_replacements == 0 and "volumeBindingMode:" not in updated:
        updated = re.sub(
            rf"(?m)^(?P<indent>\s*)provisioner:\s*{re.escape(CSI_PROVISIONER)}\s*$",
            rf"\g<indent>provisioner: {CSI_PROVISIONER}\n"
            r"\g<indent>volumeBindingMode: WaitForFirstConsumer",
            updated,
            count=1,
        )

    updated = re.sub(
        r"(?m)^(?P<indent>\s*)type:\s*gp2\s*$",
        r"\g<indent>type: gp3",
        updated,
    )
    if not re.search(r"(?m)^\s*encrypted:\s*", updated):
        updated = re.sub(
            r"(?m)^(?P<indent>\s*)type:\s*gp3\s*$",
            r'\g<indent>type: gp3\n\g<indent>encrypted: "true"',
            updated,
            count=1,
        )

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
        for pattern in ("*.yaml", "*.yml")
        for path in args.charts_dir.rglob(pattern)
        if path.is_file()
    )
    patched = [path for path in candidates if patch_storage_class(path)]

    if not patched:
        raise SystemExit("No legacy Privacera StorageClass templates were found")

    remaining = [
        path
        for path in candidates
        if "kind: StorageClass" in path.read_text(encoding="utf-8")
        and LEGACY_PROVISIONER in path.read_text(encoding="utf-8")
    ]
    if remaining:
        names = "\n".join(f"  - {path}" for path in remaining)
        raise SystemExit(f"Legacy EBS provisioners remain:\n{names}")

    print(f"Patched {len(patched)} Privacera StorageClass template(s):")
    for path in patched:
        print(f"  - {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
