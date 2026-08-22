from __future__ import annotations

import argparse
import base64
import json
import re
from collections import Counter
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

import yaml


def q1(q, key, default=""):
    v = q.get(key)
    return v[0] if v else default


def qbool(q, *keys):
    for key in keys:
        if str(q1(q, key, "")).strip().lower() in {"1", "true", "yes", "on"}:
            return True
    return False


def split_csv(value):
    return [x.strip() for x in str(value or "").split(",") if x.strip()]


def b64decode_loose(s: str) -> bytes:
    s = "".join(s.strip().split())
    s += "=" * (-len(s) % 4)
    try:
        return base64.urlsafe_b64decode(s.encode())
    except Exception:
        return base64.b64decode(s.encode())


def uri_userinfo(uri: str) -> str:
    p = urlsplit(uri)
    if "@" not in p.netloc:
        return ""
    return unquote(p.netloc.rsplit("@", 1)[0])


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
    p = urlsplit("ss://x@" + addr)
    if not p.hostname or p.port is None:
        raise ValueError("invalid Shadowsocks server address")
    return method, password, p.hostname, p.port


def xhttp_extra_to_mihomo(q):
    opts = {}
    extra_raw = q1(q, "extra", "")
    extra = {}
    if extra_raw:
        try:
            value = json.loads(extra_raw)
            if isinstance(value, dict):
                extra = value
        except Exception:
            pass

    x_padding = (
        extra.get("xPaddingBytes")
        or q1(q, "x_padding_bytes", "")
        or q1(q, "xPaddingBytes", "")
    )
    if x_padding:
        opts["x-padding-bytes"] = str(x_padding)

    for source_key, target_key in {
        "noGRPCHeader": "no-grpc-header",
        "xPaddingObfsMode": "x-padding-obfs-mode",
        "xPaddingKey": "x-padding-key",
    }.items():
        if source_key in extra:
            opts[target_key] = extra[source_key]

    headers = extra.get("headers")
    if isinstance(headers, dict) and headers:
        opts["headers"] = headers

    return opts


def mihomo_transport_options(proxy: dict, q: dict, protocol: str):
    network = (q1(q, "type", "tcp") or "tcp").lower()

    if network in {"tcp", "raw", "none"}:
        proxy["network"] = "tcp"
        return proxy

    if network == "ws":
        proxy["network"] = "ws"
        opts = {"path": unquote(q1(q, "path", "/"))}
        host = q1(q, "host", "")
        if host:
            opts["headers"] = {"Host": host}
        proxy["ws-opts"] = opts
        return proxy

    if network == "grpc":
        proxy["network"] = "grpc"
        proxy["grpc-opts"] = {
            "grpc-service-name": q1(q, "serviceName", q1(q, "service_name", "")),
        }
        return proxy

    if network == "httpupgrade":
        proxy["network"] = "ws"
        opts = {
            "path": unquote(q1(q, "path", "/")),
            "v2ray-http-upgrade": True,
        }
        host = q1(q, "host", "")
        if host:
            opts["headers"] = {"Host": host}
        proxy["ws-opts"] = opts
        return proxy

    if network == "http":
        if protocol not in {"vless", "vmess"}:
            raise ValueError(f"Mihomo {protocol} does not support http transport")
        proxy["network"] = "http"
        opts = {"path": [unquote(q1(q, "path", "/"))]}
        host = q1(q, "host", "")
        if host:
            opts["headers"] = {"Host": [host]}
        proxy["http-opts"] = opts
        return proxy

    if network in {"h2", "http2"}:
        if protocol not in {"vless", "vmess"}:
            raise ValueError(f"Mihomo {protocol} does not support h2 transport")
        proxy["network"] = "h2"
        opts = {"path": unquote(q1(q, "path", "/"))}
        host = q1(q, "host", "")
        if host:
            opts["host"] = [host]
        proxy["h2-opts"] = opts
        return proxy

    if network == "xhttp":
        if protocol != "vless":
            raise ValueError("Mihomo xhttp transport is supported for VLESS only")
        proxy["network"] = "xhttp"
        opts = {
            "path": unquote(q1(q, "path", "/")),
            "host": q1(q, "host", ""),
            "mode": q1(q, "mode", "auto"),
        }
        opts.update(xhttp_extra_to_mihomo(q))
        proxy["xhttp-opts"] = opts
        return proxy

    raise ValueError(f"unsupported Mihomo transport: {network}")


def apply_tls_fields(proxy: dict, q: dict, *, sni_key="servername"):
    sni = q1(q, "sni", "")
    if sni:
        proxy[sni_key] = sni

    alpn = split_csv(q1(q, "alpn", ""))
    if alpn:
        proxy["alpn"] = alpn

    fp = q1(q, "fp", "")
    if fp:
        proxy["client-fingerprint"] = fp

    if qbool(q, "insecure", "allowInsecure"):
        proxy["skip-cert-verify"] = True


def mihomo_proxy_from_uri(uri: str, name: str):
    p = urlsplit(uri)
    q = parse_qs(p.query, keep_blank_values=True)
    scheme = p.scheme.lower()

    if scheme == "vless":
        proxy = {
            "name": name,
            "type": "vless",
            "server": p.hostname,
            "port": p.port,
            "uuid": unquote(p.username or ""),
            "udp": True,
        }
        flow = q1(q, "flow", "")
        if flow:
            proxy["flow"] = flow

        packet_encoding = q1(q, "packetEncoding", q1(q, "packet-encoding", ""))
        if packet_encoding and packet_encoding.lower() != "none":
            proxy["packet-encoding"] = packet_encoding

        encryption = q1(q, "encryption", "")
        if encryption and encryption.lower() != "none":
            proxy["encryption"] = encryption

        security = (q1(q, "security", "") or "").lower()
        if security in {"tls", "reality"}:
            proxy["tls"] = True
            apply_tls_fields(proxy, q)

        if security == "reality":
            proxy["reality-opts"] = {
                "public-key": q1(q, "pbk", ""),
                "short-id": q1(q, "sid", ""),
            }

        return mihomo_transport_options(proxy, q, "vless")

    if scheme == "trojan":
        proxy = {
            "name": name,
            "type": "trojan",
            "server": p.hostname,
            "port": p.port,
            "password": uri_userinfo(uri),
            "udp": True,
        }
        apply_tls_fields(proxy, q, sni_key="sni")
        security = (q1(q, "security", "") or "").lower()
        if security == "reality" or q1(q, "pbk", ""):
            proxy["reality-opts"] = {
                "public-key": q1(q, "pbk", ""),
                "short-id": q1(q, "sid", ""),
            }
        return mihomo_transport_options(proxy, q, "trojan")

    if scheme == "vmess":
        o = parse_vmess_uri(uri)
        proxy = {
            "name": name,
            "type": "vmess",
            "server": o.get("add"),
            "port": int(o.get("port")),
            "uuid": o.get("id"),
            "alterId": int(o.get("aid", 0) or 0),
            "cipher": o.get("scy", "auto"),
            "udp": True,
        }

        if str(o.get("tls", "")).lower() == "tls":
            proxy["tls"] = True
            if o.get("sni"):
                proxy["servername"] = o.get("sni")
            alpn = split_csv(o.get("alpn", ""))
            if alpn:
                proxy["alpn"] = alpn
            if o.get("fp"):
                proxy["client-fingerprint"] = o.get("fp")

            insecure_value = str(
                o.get(
                    "allowInsecure",
                    o.get("insecure", o.get("skip-cert-verify", "0")),
                )
            ).lower()
            if insecure_value in {"1", "true", "yes", "on"}:
                proxy["skip-cert-verify"] = True

        packet_encoding = o.get("packetEncoding") or o.get("packet-encoding")
        if packet_encoding and str(packet_encoding).lower() != "none":
            proxy["packet-encoding"] = packet_encoding

        fake_q = {
            "type": [o.get("net", "tcp")],
            "path": [o.get("path", "")],
            "host": [o.get("host", "")],
            "serviceName": [o.get("serviceName", o.get("service_name", ""))],
            "mode": [o.get("mode", "auto")],
        }
        return mihomo_transport_options(proxy, fake_q, "vmess")

    if scheme == "ss":
        method, password, host, port = parse_ss_uri(uri)
        return {
            "name": name,
            "type": "ss",
            "server": host,
            "port": port,
            "cipher": method,
            "password": password,
            "udp": True,
        }

    if scheme in {"hy2", "hysteria2"}:
        proxy = {
            "name": name,
            "type": "hysteria2",
            "server": p.hostname,
            "port": p.port,
            "password": uri_userinfo(uri),
            "sni": q1(q, "sni", p.hostname or ""),
            "skip-cert-verify": qbool(q, "insecure", "allowInsecure"),
            "udp": True,
        }

        obfs = q1(q, "obfs", "")
        if obfs:
            proxy["obfs"] = obfs
            proxy["obfs-password"] = q1(
                q, "obfs-password", q1(q, "obfs_password", "")
            )

        alpn = split_csv(q1(q, "alpn", ""))
        if alpn:
            proxy["alpn"] = alpn

        up = q1(q, "upmbps", "")
        down = q1(q, "downmbps", "")
        if up:
            proxy["up"] = f"{up} Mbps" if re.fullmatch(r"\d+(?:\.\d+)?", up) else up
        if down:
            proxy["down"] = f"{down} Mbps" if re.fullmatch(r"\d+(?:\.\d+)?", down) else down

        ports = q1(q, "ports", q1(q, "mport", ""))
        if ports:
            proxy["ports"] = ports

        hop = q1(q, "hop-interval", q1(q, "hop_interval", ""))
        if hop:
            try:
                proxy["hop-interval"] = int(hop)
            except ValueError:
                proxy["hop-interval"] = hop

        return proxy

    if scheme == "tuic":
        userinfo = uri_userinfo(uri)
        if ":" not in userinfo:
            raise ValueError("TUIC URI must contain uuid:password before @")
        uuid, password = userinfo.split(":", 1)
        proxy = {
            "name": name,
            "type": "tuic",
            "server": p.hostname,
            "port": p.port,
            "uuid": uuid,
            "password": password,
            "udp-relay-mode": q1(q, "udp_relay_mode", q1(q, "udp-relay-mode", "native")),
            "congestion-controller": q1(
                q, "congestion_control", q1(q, "congestion-controller", "bbr")
            ),
        }
        sni = q1(q, "sni", "")
        if sni:
            proxy["sni"] = sni
        alpn = split_csv(q1(q, "alpn", ""))
        if alpn:
            proxy["alpn"] = alpn
        if qbool(q, "insecure", "allowInsecure"):
            proxy["skip-cert-verify"] = True
        return proxy

    raise ValueError(f"unsupported Mihomo protocol: {scheme}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", default="output/unique.txt")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--output-dir", default="yandex_probe/generated")
    args = parser.parse_args()

    src = Path(args.input)
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    uris = [
        line.strip()
        for line in src.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ][: args.limit]

    proxies = []
    errors = []
    protocols = Counter()

    for i, uri in enumerate(uris, start=1):
        scheme = uri.split("://", 1)[0].lower()
        protocols[scheme] += 1
        name = f"ru-{i:06d}"
        try:
            proxies.append(mihomo_proxy_from_uri(uri, name))
        except Exception as exc:
            errors.append(
                {
                    "index": i,
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

    meta = {
        "requested": args.limit,
        "selected": len(uris),
        "converted": len(proxies),
        "conversion_failed": len(errors),
        "protocols_selected": dict(protocols),
        "conversion_errors": errors[:100],
        "group_name": group_name,
    }
    (out_dir / "meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    print(json.dumps(meta, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
