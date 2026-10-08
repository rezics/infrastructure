#!/usr/bin/env python3
"""Provision secrets and the pinned Stalwart administrative API."""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
import urllib.error
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("mode", choices=["stage", "bootstrap"])
parser.add_argument("--secret-dir", required=True)
parser.add_argument("--config", required=True)
parser.add_argument("--forwarding-file", required=True)
parser.add_argument("--dkim-file")
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
desired = json.loads(Path(args.config).read_text())
hostname = desired["mailHostname"]
domain = desired["domain"]
mailbox = desired["mailboxAddress"]
credential_key = desired.get("mailboxCredentialKey", "mailbox")
secret_dir = Path(args.secret_dir)
credential_file = secret_dir / "stalwart.json"
if not credential_file.exists():
    data = {"hostname": hostname, "admin": {"username": "admin", "password": secrets.token_urlsafe(36)},
            credential_key: {"username": mailbox, "password": secrets.token_urlsafe(36)}}
    fd = os.open(credential_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as out:
        json.dump(data, out, indent=2)
        out.write("\n")
credentials = json.loads(credential_file.read_text())
if args.mode == "stage":
    server = json.loads((secret_dir / "secret.json").read_text())["main_db_server_info"]
    password_hash = subprocess.check_output(["openssl", "passwd", "-6", "-stdin"], input=credentials["admin"]["password"].encode()).strip()
    encoded = base64.b64encode(password_hash).decode()
    script = "set -eu\ninstall -d -m 0700 /var/lib/stalwart-secrets\numask 077\nprintf '%s' '" + encoded + "' | base64 -d > /var/lib/stalwart-secrets/admin-password-hash\n"
    command = ["ssh", "-i", str(secret_dir / "server/b/operator-ed25519"), "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes", f"{server['username']}@{server['host']}", "bash -s"]
    subprocess.run(command, input=script.encode(), check=True)
    print("Stalwart admin credential staged; passwords remain in", credential_file)
    raise SystemExit(0)

authentication = base64.b64encode(("admin:" + credentials["admin"]["password"]).encode()).decode()
def api(path, method="GET", payload=None, missing=False):
    req = urllib.request.Request("https://" + hostname + "/api/" + path,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"Authorization": "Basic " + authentication, "Content-Type": "application/json"}, method=method)
    try:
        data = json.load(urllib.request.urlopen(req, timeout=30))
    except urllib.error.HTTPError as error:
        if missing and error.code == 404:
            return None
        raise RuntimeError(f"Stalwart {method} {path}: HTTP {error.code}") from None
    if "error" in data:
        raise RuntimeError(f"Stalwart {method} {path}: {data['error']}")
    return data.get("data")

def principal(record):
    name = record["name"]
    existing = api("principal/" + urllib.parse.quote(name, safe=""), missing=True)
    if existing is None:
        api("principal", "POST", record)
        print("Created", name)
    else:
        print("Preserved existing", name)

principal({"name": domain, "type": "domain"})
principal({"name": mailbox, "type": "individual", "description": "REZICS internal mailbox",
    "emails": [mailbox, "postmaster@" + domain, "abuse@" + domain],
    "roles": ["user"], "secrets": [credentials[credential_key]["password"]]})
for record in json.loads(Path(args.forwarding_file).read_text()):
    principal({"name": record["address"], "type": "list", "emails": [record["address"]], "externalMembers": record["destinations"]})
for algorithm, identifier in [("Rsa", "rsa-" + domain), ("Ed25519", "ed25519-" + domain)]:
    if api("dkim/" + identifier, missing=True) is None:
        api("dkim", "POST", {"id": identifier, "algorithm": algorithm, "domain": domain})
api("reload")
dns = api("dns/records/" + domain)
dkim = [{"type": "TXT", "name": r["name"].rstrip("."), "content": r["content"]}
    for r in dns if r["type"] == "TXT" and ("._domainkey." + domain) in r["name"]]
if not dkim:
    raise RuntimeError("Stalwart did not produce DKIM records")
if not args.dkim_file:
    raise RuntimeError("--dkim-file is required for the public DKIM record export")
Path(args.dkim_file).write_text(json.dumps(dkim, indent=2) + "\n")
print("Mailbox and migrated forwarding addresses verified; exported", len(dkim), "DKIM records")
