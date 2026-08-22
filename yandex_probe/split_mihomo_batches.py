#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

import yaml


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--meta", required=True)
    ap.add_argument("--output-dir", required=True)
    ap.add_argument("--chunk-size", type=int, default=1000)
    args = ap.parse_args()

    config_path = Path(args.config)
    meta_path = Path(args.meta)
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    config = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    meta = json.loads(meta_path.read_text(encoding="utf-8"))

    proxies = list(config.get("proxies") or [])
    if not proxies:
        raise SystemExit("No proxies in sanitized Mihomo config")

    proxy_names = {p["name"] for p in proxies}

    chunks = []
    for start in range(0, len(proxies), args.chunk_size):
        chunk_proxies = proxies[start:start + args.chunk_size]
        chunk_names = {p["name"] for p in chunk_proxies}

        chunk_config = dict(config)
        chunk_config["proxies"] = chunk_proxies

        groups = []
        for group in config.get("proxy-groups", []):
            g = dict(group)
            if isinstance(g.get("proxies"), list):
                g["proxies"] = [
                    name for name in g["proxies"]
                    if name in chunk_names
                ]
            groups.append(g)
        chunk_config["proxy-groups"] = groups

        index = len(chunks) + 1
        filename = f"config_{index:03d}.yaml"
        (out_dir / filename).write_text(
            yaml.safe_dump(
                chunk_config,
                allow_unicode=True,
                sort_keys=False,
            ),
            encoding="utf-8",
        )

        chunks.append(
            {
                "index": index,
                "file": filename,
                "count": len(chunk_proxies),
                "first_proxy": chunk_proxies[0]["name"],
                "last_proxy": chunk_proxies[-1]["name"],
            }
        )

    manifest = {
        "chunk_size": args.chunk_size,
        "total_proxies": len(proxies),
        "chunks_total": len(chunks),
        "chunks": chunks,
    }

    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
