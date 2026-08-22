#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

import yaml

# Reuse the already-tested URI -> Mihomo conversion logic.
from build_compare_batch import mihomo_proxy_from_uri


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", default="output/unique.txt")
    parser.add_argument("--limit", type=int, default=10000)
    parser.add_argument("--output-dir", default="yandex_probe/generated_ru_output")
    args = parser.parse_args()

    src = Path(args.input)
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    all_uris = [
        line.strip()
        for line in src.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]

    if args.limit <= 0 or args.limit >= len(all_uris):
        selected_pairs = list(enumerate(all_uris, start=1))
        sample_strategy = "all"
    else:
        n = len(all_uris)
        chosen_indexes = []
        seen = set()

        for i in range(args.limit):
            idx = min(n - 1, int(i * n / args.limit))
            if idx not in seen:
                seen.add(idx)
                chosen_indexes.append(idx)

        if len(chosen_indexes) < args.limit:
            for idx in range(n):
                if idx not in seen:
                    chosen_indexes.append(idx)
                    seen.add(idx)
                    if len(chosen_indexes) >= args.limit:
                        break

        selected_pairs = [(idx + 1, all_uris[idx]) for idx in chosen_indexes]
        sample_strategy = "deterministic_spread"

    proxies = []
    mapping = {}
    errors = []
    protocols = Counter()

    for selected_index, (source_index, uri) in enumerate(selected_pairs, start=1):
        scheme = uri.split("://", 1)[0].lower()
        protocols[scheme] += 1
        name = f"ru-{selected_index:06d}"

        try:
            proxy = mihomo_proxy_from_uri(uri, name)
            proxies.append(proxy)

            mapping[name] = {
                "uri": uri,
                "protocol": scheme,
                "selected_index": selected_index,
                "source_index": source_index,
            }
        except Exception as exc:
            errors.append(
                {
                    "selected_index": selected_index,
                    "source_index": source_index,
                    "name": name,
                    "protocol": scheme,
                    "error": f"{type(exc).__name__}: {exc}",
                }
            )

    if not proxies:
        raise SystemExit("No configs could be converted to Mihomo")

    group_name = "RU-BATCH"

    config = {
        "mixed-port": 7890,
        "allow-lan": False,
        "mode": "rule",
        "log-level": "warning",
        "ipv6": False,
        "external-controller": "127.0.0.1:9090",
        "profile": {
            "store-selected": False,
            "store-fake-ip": False,
        },
        "proxies": proxies,
        "proxy-groups": [
            {
                "name": group_name,
                "type": "select",
                "proxies": [proxy["name"] for proxy in proxies],
            }
        ],
        "rules": [f"MATCH,{group_name}"],
    }

    (out_dir / "config.yaml").write_text(
        yaml.safe_dump(config, allow_unicode=True, sort_keys=False),
        encoding="utf-8",
    )

    (out_dir / "mapping.json").write_text(
        json.dumps(mapping, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )

    meta = {
        "requested": args.limit,
        "pool_size": len(all_uris),
        "sample_strategy": sample_strategy,
        "selected": len(selected_pairs),
        "converted": len(proxies),
        "conversion_failed": len(errors),
        "protocols_selected": dict(protocols),
        "conversion_errors": errors[:100],
        "group_name": group_name,
        "mapping_entries": len(mapping),
    }

    (out_dir / "meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    print(json.dumps(meta, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
