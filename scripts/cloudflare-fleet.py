#!/usr/bin/env python3
"""Apply checked-in ingress and mail DNS without logging credentials."""
import argparse
import json
from pathlib import Path
import re
import urllib.error
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("mode", choices=["prepare", "cutover", "retire", "inspect"])
parser.add_argument("--token-file", required=True)
parser.add_argument("--config", required=True)
parser.add_argument("--dkim-file")
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
desired = json.loads(Path(args.config).read_text())
token = json.loads(re.sub(r",\s*}", "}", Path(args.token_file).read_text()))["token"]

def api(path, method="GET", payload=None):
    request = urllib.request.Request(
        "https://api.cloudflare.com/client/v4/" + path,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        method=method,
    )
    try:
        result = json.load(urllib.request.urlopen(request, timeout=30))
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"Cloudflare {method} {path}: HTTP {error.code}") from None
    if not result.get("success"):
        raise RuntimeError(f"Cloudflare {method} {path}: request failed")
    return result["result"]

zone_info = api("zones?name=" + desired["domain"])[0]
zone, account = zone_info["id"], zone_info["account"]["id"]

def records():
    return api(f"zones/{zone}/dns_records?per_page=100")

def upsert(record):
    existing = [r for r in records() if r["type"] == record["type"] and r["name"] == record["name"]]
    if record["type"] == "MX":
        existing = [r for r in existing if r["content"] == record["content"]]
    if len(existing) > 1:
        raise RuntimeError("Ambiguous DNS record: " + record["name"])
    payload = {"ttl": 300, **record}
    if existing:
        api(f"zones/{zone}/dns_records/{existing[0]['id']}", "PUT", payload)
    else:
        api(f"zones/{zone}/dns_records", "POST", payload)
    print("Configured", record["type"], record["name"])

if args.mode == "prepare":
    upsert({"type": "A", "name": desired["mailHostname"], "content": desired["mailAddress"], "proxied": False})
elif args.mode == "cutover":
    if not args.dkim_file:
        raise RuntimeError("Verified Stalwart DKIM records are required before MX cutover")
    for record in json.loads(Path(args.dkim_file).read_text()):
        if record["type"] != "TXT" or not record["name"].endswith("._domainkey." + desired["domain"]):
            raise RuntimeError("Unexpected DKIM record")
        upsert(record)
    api(f"zones/{zone}/email/routing/dns", "PATCH", {"name": desired["domain"]})
    upsert({"type": "MX", "name": desired["domain"], "content": desired["mailHostname"], "priority": 10})
    for record in records():
        if record["type"] == "MX" and record["name"] == desired["domain"] and record["content"].endswith(".mx.cloudflare.net"):
            api(f"zones/{zone}/dns_records/{record['id']}", "DELETE")
    upsert({"type": "TXT", "name": desired["domain"], "content": "v=spf1 ip4:" + desired["mailAddress"] + " include:_spf.mx.cloudflare.net -all"})
    upsert({"type": "TXT", "name": desired["mailHostname"], "content": "v=spf1 ip4:" + desired["mailAddress"] + " -all"})
elif args.mode == "retire":
    tunnels = api(f"accounts/{account}/cfd_tunnel?is_deleted=false")
    for tunnel in tunnels:
        current = api(f"accounts/{account}/cfd_tunnel/{tunnel['id']}/configurations")
        config = current.get("config") or {}
        ingress = config.get("ingress", [])
        retained = [r for r in ingress if r.get("hostname") not in desired["retiredHostnames"]]
        if retained != ingress:
            config["ingress"] = retained
            api(f"accounts/{account}/cfd_tunnel/{tunnel['id']}/configurations", "PUT", {"config": config})
    for record in records():
        if record["name"] in desired["retiredHostnames"] and record["type"] in ["A", "AAAA", "CNAME"]:
            api(f"zones/{zone}/dns_records/{record['id']}", "DELETE")
    for worker in api(f"accounts/{account}/workers/scripts"):
        if worker["id"] in desired["retiredWorkers"]:
            api(f"accounts/{account}/workers/scripts/{worker['id']}?force=true", "DELETE")
            print("Deleted retired Worker", worker["id"])
else:
    for record in records():
        if record["name"] in [desired["domain"], desired["mailHostname"]] or record["name"].startswith("cf-bounce"):
            print(record["type"], record["name"], record["content"])
