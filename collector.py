from __future__ import annotations

import base64
import json
import os
import re
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import parse_qsl, unquote, urlsplit
from urllib.request import Request, urlopen

SOURCES_FILE = Path("sources.txt")
OUT_DIR = Path("output")
UNIQUE_FILE = OUT_DIR / "unique.txt"
STATS_FILE = OUT_DIR / "collect_stats.json"

SUPPORTED = {
    "vless",
    "vmess",
    "trojan",
    "ss",
    "hysteria2",
    "hy2",
    "tuic",
}

FETCH_TIMEOUT = float(os.getenv("FETCH_TIMEOUT_SECONDS", "30"))
FETCH_WORKERS = int(os.getenv("FETCH_WORKERS", "16"))
MAX_UNIQUE = int(os.getenv("MAX_UNIQUE", "10000"))

URI_RE = re.compile(
    r"(?:(?:vless|vmess|trojan|ss|hysteria2|hy2|tuic)://)[^\s]+",
    re.IGNORECASE,
)


def b64decode_loose(value: str) -> bytes:
    value = "".join(value.strip().split())
    value += "=" * (-len(value) % 4)
    try:
        return base64.urlsafe_b64decode(value.encode())
    except Exception:
        return base64.b64decode(value.encode())


def parse_vmess_uri(uri: str) -> dict:
    raw = uri[len("vmess://"):].split("#", 1)[0]
    return json.loads(b64decode_loose(raw).decode("utf-8", errors="strict"))


def parse_ss_uri(uri: str):
    raw = uri[len("ss://"):].split("#", 1)[0].split("?", 1)[0]

    if "@" in raw:
        cred_raw, addr = raw.rsplit("@", 1)
        cred_decoded = unquote(cred_raw)
        if ":" not in cred_decoded:
            cred_decoded = b64decode_loose(cred_raw).decode("utf-8", errors="strict")
    else:
        decoded = b64decode_loose(raw).decode("utf-8", errors="strict")
        cred_decoded, addr = decoded.rsplit("@", 1)

    method, password = cred_decoded.split(":", 1)
    parsed = urlsplit("ss://x@" + addr)
    if not parsed.hostname or parsed.port is None:
        raise ValueError("invalid Shadowsocks server address")

    return method, password, parsed.hostname, parsed.port


def uri_userinfo(uri: str) -> str:
    parsed = urlsplit(uri)
    if "@" not in parsed.netloc:
        return ""
    return unquote(parsed.netloc.rsplit("@", 1)[0])


def canonical(uri: str) -> str:
    """
    Conservative semantic key used only for deduplication.

    Display fragments are ignored. Connection-significant fields remain
    significant. Different endpoints sharing the same UUID are NOT collapsed.
    """
    uri = uri.strip()

    def raw_key():
        return "raw-uri:" + uri.split("#", 1)[0].strip()

    def normalized_query_pairs(query: str, *, vless_defaults: bool = False):
        pairs = parse_qsl(query, keep_blank_values=True)
        names = [key for key, _ in pairs]

        # Repeated fields are ambiguous; do not reorder/collapse them.
        if len(names) != len(set(names)):
            return None

        if vless_defaults:
            present = set(names)
            if "encryption" not in present:
                pairs.append(("encryption", "none"))
            if "security" not in present:
                pairs.append(("security", "none"))

        return sorted(pairs)

    try:
        scheme = uri.split("://", 1)[0].lower()
        canonical_scheme = "hysteria2" if scheme == "hy2" else scheme

        if scheme == "vmess":
            data = dict(parse_vmess_uri(uri))
            for cosmetic_key in ("ps", "remark", "remarks", "name"):
                data.pop(cosmetic_key, None)

            if data.get("add"):
                data["add"] = str(data["add"]).lower().rstrip(".")
            if data.get("port") is not None:
                data["port"] = str(data["port"])

            return "vmess:" + json.dumps(
                data,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            )

        if scheme == "ss":
            method, password, host, port = parse_ss_uri(uri)
            parsed = urlsplit(uri)
            query_pairs = normalized_query_pairs(parsed.query)
            if query_pairs is None:
                return raw_key()

            payload = {
                "scheme": "ss",
                "method": method,
                "password": password,
                "host": host.lower().rstrip("."),
                "port": port,
                "query": query_pairs,
            }
            return json.dumps(
                payload,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            )

        parsed = urlsplit(uri)
        query_pairs = normalized_query_pairs(
            parsed.query,
            vless_defaults=(scheme == "vless"),
        )
        if query_pairs is None:
            return raw_key()

        payload = {
            "scheme": canonical_scheme,
            "userinfo": uri_userinfo(uri),
            "host": (parsed.hostname or "").lower().rstrip("."),
            "port": parsed.port,
            "path": parsed.path,
            "query": query_pairs,
        }
        return json.dumps(
            payload,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )

    except Exception:
        return raw_key()


def validate_basic(uri: str) -> bool:
    """
    Syntax/basic-structure validation only.
    NO DNS, TCP, latency or other network verdict is performed here.
    """
    try:
        scheme = uri.split("://", 1)[0].lower()
        if scheme not in SUPPORTED:
            return False

        if scheme == "vmess":
            data = parse_vmess_uri(uri)
            return bool(data.get("add") and data.get("port"))

        if scheme == "ss":
            _, _, host, port = parse_ss_uri(uri)
            return bool(host and port)

        parsed = urlsplit(uri)
        return bool(parsed.hostname and parsed.port)

    except Exception:
        return False


def fetch(url: str) -> str:
    req = Request(
        url,
        headers={
            "User-Agent": "vpn-checker-ru/0.1",
            "Accept": "text/plain,*/*",
        },
    )
    with urlopen(req, timeout=FETCH_TIMEOUT) as response:
        return response.read().decode("utf-8", errors="replace")


def maybe_decode_subscription(text: str) -> str:
    # Plain-text subscriptions are preferred.
    if URI_RE.search(text):
        return text

    compact = "".join(text.split())
    if not compact:
        return text

    try:
        decoded = b64decode_loose(compact).decode("utf-8", errors="replace")
        if URI_RE.search(decoded):
            return decoded
    except Exception:
        pass

    return text


def extract_uris(text: str) -> list[str]:
    """
    Supports both one-URI-per-line subscriptions and mixed text containing
    supported share links.
    """
    text = maybe_decode_subscription(text)
    found: list[str] = []

    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue

        # Fast path: normal subscription line.
        if "://" in line:
            scheme = line.split("://", 1)[0].lower()
            if scheme in SUPPORTED:
                found.append(line)
                continue

        # Fallback for mixed-format pages/text.
        for match in URI_RE.findall(line):
            found.append(match.strip())

    return found


def load_sources() -> list[str]:
    if not SOURCES_FILE.exists():
        raise SystemExit(f"Missing {SOURCES_FILE}")

    result = []
    seen = set()

    for line in SOURCES_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line not in seen:
            seen.add(line)
            result.append(line)

    if not result:
        raise SystemExit("sources.txt contains no source URLs")

    return result


def collect():
    sources = load_sources()
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    per_source = {}
    downloaded = {}

    # Source downloads are parallelized. This is collection only; no VPN keys
    # are tested from GitHub or from the machine running this collector.
    with ThreadPoolExecutor(max_workers=min(FETCH_WORKERS, len(sources))) as pool:
        future_to_url = {pool.submit(fetch, url): url for url in sources}
        for future in as_completed(future_to_url):
            url = future_to_url[future]
            try:
                downloaded[url] = future.result()
            except Exception as exc:
                per_source[url] = {
                    "download_ok": False,
                    "error": str(exc),
                    "found": 0,
                    "valid": 0,
                    "malformed": 0,
                    "duplicates": 0,
                    "unique_contribution": 0,
                }

    unique: dict[str, str] = {}
    total_found = 0
    total_valid = 0
    total_malformed = 0
    total_duplicates = 0

    # Preserve sources.txt order for deterministic duplicate attribution/output.
    for url in sources:
        if url not in downloaded:
            continue

        uris = extract_uris(downloaded[url])
        stats = {
            "download_ok": True,
            "found": len(uris),
            "valid": 0,
            "malformed": 0,
            "duplicates": 0,
            "unique_contribution": 0,
        }

        total_found += len(uris)

        for uri in uris:
            uri = uri.strip()
            if not validate_basic(uri):
                stats["malformed"] += 1
                total_malformed += 1
                continue

            stats["valid"] += 1
            total_valid += 1

            key = canonical(uri)
            if key in unique:
                stats["duplicates"] += 1
                total_duplicates += 1
                continue

            unique[key] = uri
            stats["unique_contribution"] += 1

            if MAX_UNIQUE > 0 and len(unique) >= MAX_UNIQUE:
                break

        per_source[url] = stats

        if MAX_UNIQUE > 0 and len(unique) >= MAX_UNIQUE:
            break

    UNIQUE_FILE.write_text(
        "\n".join(unique.values()) + ("\n" if unique else ""),
        encoding="utf-8",
    )

    protocol_counts = {scheme: 0 for scheme in sorted(SUPPORTED)}
    for uri in unique.values():
        scheme = uri.split("://", 1)[0].lower()
        protocol_counts[scheme] = protocol_counts.get(scheme, 0) + 1

    summary = {
        "max_unique": MAX_UNIQUE,
        "sources_total": len(sources),
        "sources_downloaded": sum(
            1 for item in per_source.values() if item.get("download_ok")
        ),
        "found": total_found,
        "valid_before_dedup": total_valid,
        "malformed": total_malformed,
        "duplicates": total_duplicates,
        "unique": len(unique),
        "protocols": protocol_counts,
        "per_source": per_source,
    }

    STATS_FILE.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\nSaved {len(unique)} unique configs to {UNIQUE_FILE}")


if __name__ == "__main__":
    collect()
