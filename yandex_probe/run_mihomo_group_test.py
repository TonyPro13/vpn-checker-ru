#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path


def wait_controller(url: str, proc: subprocess.Popen, timeout: float = 15.0) -> None:
    deadline = time.time() + timeout
    last_error = None
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"Mihomo exited early with code {proc.returncode}")
        try:
            with urllib.request.urlopen(url + "/version", timeout=1.0) as r:
                if r.status == 200:
                    return
        except Exception as exc:
            last_error = exc
        time.sleep(0.1)
    raise RuntimeError(f"Mihomo controller not ready: {last_error}")


def percentile(values, p):
    if not values:
        return None
    values = sorted(values)
    if len(values) == 1:
        return values[0]
    rank = (len(values) - 1) * p
    lo = int(rank)
    hi = min(lo + 1, len(values) - 1)
    frac = rank - lo
    return round(values[lo] * (1 - frac) + values[hi] * frac, 2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mihomo", default="./mihomo")
    ap.add_argument("--config", required=True)
    ap.add_argument("--meta", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--label", default="github")
    ap.add_argument("--controller", default="http://127.0.0.1:9090")
    ap.add_argument("--group", default="RU-BATCH")
    ap.add_argument("--timeout-ms", type=int, default=5000)
    ap.add_argument("--url", default="https://cp.cloudflare.com")
    args = ap.parse_args()

    work = Path("mihomo-run")
    work.mkdir(exist_ok=True)
    stdout_path = work / "mihomo.stdout.log"
    stderr_path = work / "mihomo.stderr.log"

    with stdout_path.open("wb") as stdout_f, stderr_path.open("wb") as stderr_f:
        proc = subprocess.Popen(
            [args.mihomo, "-d", str(work), "-f", args.config],
            stdout=stdout_f,
            stderr=stderr_f,
        )

        try:
            wait_controller(args.controller, proc)

            q = urllib.parse.urlencode(
                {"timeout": args.timeout_ms, "url": args.url}
            )
            endpoint = (
                args.controller
                + "/group/"
                + urllib.parse.quote(args.group, safe="")
                + "/delay?"
                + q
            )

            started = time.perf_counter()
            with urllib.request.urlopen(
                endpoint,
                timeout=max(30.0, args.timeout_ms / 1000 + 25.0),
            ) as r:
                raw = r.read().decode("utf-8", errors="replace")
            elapsed_ms = round((time.perf_counter() - started) * 1000)

            payload = json.loads(raw)
            meta = json.loads(Path(args.meta).read_text(encoding="utf-8"))

            delays = {
                k: v
                for k, v in payload.items()
                if isinstance(v, (int, float)) and v > 0
            }
            sorted_items = sorted(delays.items(), key=lambda kv: kv[1])
            vals = [v for _, v in sorted_items]

            result = {
                "ok": True,
                "location": args.label,
                "elapsed_ms": elapsed_ms,
                "requested": meta.get("requested"),
                "pool_size": meta.get("pool_size"),
                "selected": meta.get("selected"),
                "converted": meta.get("converted"),
                "conversion_failed": meta.get("conversion_failed"),
                "protocols_selected": meta.get("protocols_selected", {}),
                "alive": len(delays),
                "dead_or_timeout": max(0, int(meta.get("converted", 0)) - len(delays)),
                "latency_ms": {
                    "min": min(vals) if vals else None,
                    "p50": percentile(vals, 0.50),
                    "p90": percentile(vals, 0.90),
                    "max": max(vals) if vals else None,
                    "average": round(sum(vals) / len(vals), 2) if vals else None,
                },
                "fastest_20": [
                    {"name": name, "delay": delay}
                    for name, delay in sorted_items[:20]
                ],
                "delays": payload,
            }

            Path(args.output).write_text(
                json.dumps(result, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
            print(json.dumps(
                {k: v for k, v in result.items() if k != "delays"},
                ensure_ascii=False,
                indent=2,
            ))
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


if __name__ == "__main__":
    main()
