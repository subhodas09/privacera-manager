#!/usr/bin/env python3
"""Inject Snowflake GitHub Actions secrets into a temporary connector YAML."""

import argparse
import json
import os
import re
from pathlib import Path


KEYS = {
    "CONNECTOR_SNOWFLAKE_JDBC_PASSWORD": "SNOWFLAKE_JDBC_PASSWORD",
    "CONNECTOR_SNOWFLAKE_DEFAULT_USER_PASSWORD": "SNOWFLAKE_DEFAULT_USER_PASSWORD",
}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", required=True, type=Path)
    args = parser.parse_args()

    missing_env = [env for env in KEYS.values() if not os.environ.get(env)]
    if missing_env:
        raise SystemExit("Missing required environment variable(s): " + ", ".join(missing_env))

    content = args.file.read_text(encoding="utf-8")
    for yaml_key, env_key in KEYS.items():
        replacement = f"{yaml_key}: {json.dumps(os.environ[env_key])}"
        content, count = re.subn(
            rf"(?m)^{re.escape(yaml_key)}\s*:.*$", replacement, content, count=1
        )
        if count != 1:
            raise SystemExit(f"Expected exactly one YAML key: {yaml_key}")

    args.file.write_text(content, encoding="utf-8")
    print(f"Injected {len(KEYS)} Snowflake secrets into {args.file} (values not printed)")


if __name__ == "__main__":
    main()
