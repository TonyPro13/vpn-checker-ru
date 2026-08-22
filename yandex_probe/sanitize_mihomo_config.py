#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

import yaml


def validate(mihomo: str, config: dict) -> tuple[bool, str]:
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        suffix=".yaml",
        delete=False,
    ) as f:
        yaml.safe_dump(config, f, allow_unicode=True, sort_keys=False)
        path = f.name

    try:
        proc = subprocess.run(
            [mihomo, "-t", "-f", path],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
        )
        return proc.returncode == 0, proc.stdout
    finally:
        Path(path).unlink(missing_ok=True)


def config_for_subset(base: dict, proxies: list[dict]) -> dict:
    cfg = dict(base)
    cfg["proxies"] = proxies

    group_names = {p["name"] for p in proxies}
    groups = []
    for group in base.get("proxy-groups", []):
        g = dict(group)
        if isinstance(g.get("proxies"), list):
            g["proxies"] = [
                name for name in g["proxies"] if name in group_names
            ]
        groups.append(g)
    cfg["proxy-groups"] = groups
    return cfg


def find_valid_and_invalid(
    mihomo: str,
    base: dict,
    indexed_proxies: list[tuple[int, dict]],
    rejected: list[dict],
) -> list[tuple[int, dict]]:
    if not indexed_proxies:
        return []

    subset = [p for _, p in indexed_proxies]
    ok, output = validate(mihomo, config_for_subset(base, subset))

    if ok:
        return indexed_proxies

    if len(indexed_proxies) == 1:
        original_index, proxy = indexed_proxies[0]
        rejected.append(
            {
                "source_index_in_converted_batch": original_index,
                "name": proxy.get("name"),
                "type": proxy.get("type"),
                "server": proxy.get("server"),
                "port": proxy.get("port"),
                "validation_error": output.strip()[-4000:],
            }
        )
        return []

    mid = len(indexed_proxies) // 2
    left = find_valid_and_invalid(
        mihomo, base, indexed_proxies[:mid], rejected
    )
    right = find_valid_and_invalid(
        mihomo, base, indexed_proxies[mid:], rejected
    )
    return left + right


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mihomo", default="./mihomo")
    ap.add_argument("--config", required=True)
    ap.add_argument("--meta", required=True)
    ap.add_argument("--rejected", required=True)
    args = ap.parse_args()

    config_path = Path(args.config)
    meta_path = Path(args.meta)

    config = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    meta = json.loads(meta_path.read_text(encoding="utf-8"))

    proxies = list(config.get("proxies") or [])
    indexed = list(enumerate(proxies, start=1))

    # Check the full config first. In the usual case this is one cheap call.
    full_ok, full_output = validate(args.mihomo, config)
    if full_ok:
        rejected = []
        valid_indexed = indexed
    else:
        rejected = []
        valid_indexed = find_valid_and_invalid(
            args.mihomo, config, indexed, rejected
        )

    valid_proxies = [p for _, p in valid_indexed]
    sanitized = config_for_subset(config, valid_proxies)

    # Final mandatory validation of the exact config that will be tested.
    final_ok, final_output = validate(args.mihomo, sanitized)
    if not final_ok:
        raise SystemExit(
            "Sanitized config is still invalid:\n" + final_output
        )

    config_path.write_text(
        yaml.safe_dump(
            sanitized,
            allow_unicode=True,
            sort_keys=False,
        ),
        encoding="utf-8",
    )

    meta["mihomo_validation"] = {
        "input_converted": len(proxies),
        "accepted": len(valid_proxies),
        "rejected": len(rejected),
    }
    meta["converted_before_mihomo_validation"] = meta.get("converted")
    meta["converted"] = len(valid_proxies)

    meta_path.write_text(
        json.dumps(meta, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    rejected_path = Path(args.rejected)
    rejected_path.write_text(
        json.dumps(rejected, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    print(
        json.dumps(
            {
                "full_config_was_valid": full_ok,
                "input_converted": len(proxies),
                "accepted": len(valid_proxies),
                "rejected": len(rejected),
                "rejected_preview": rejected[:10],
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
