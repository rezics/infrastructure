#!/usr/bin/env python3
"""Stage runtime credentials for the source-controlled Stalwart service."""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("mode", choices=["stage"])
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
    if not args.dkim_file:
        raise RuntimeError("--dkim-file must reference the private initial DKIM records")
    initial = {"mailbox": credentials[credential_key], "dkim": json.loads(Path(args.dkim_file).read_text())}
    for record in initial["dkim"]:
        if "selector" not in record or "privateKey" not in record:
            raise RuntimeError("Invalid initial DKIM record")
        record.pop("domainId", None)
    server = json.loads((secret_dir / "secret.json").read_text())["main_db_server_info"]
    password_hash = subprocess.check_output(["openssl", "passwd", "-6", "-stdin"], input=credentials["admin"]["password"].encode()).strip()
    encoded = base64.b64encode(password_hash).decode()
    script = "set -eu\ninstall -d -m 0700 /var/lib/stalwart-secrets\numask 077\nprintf '%s' '" + encoded + "' | base64 -d > /var/lib/stalwart-secrets/admin-password-hash\n"
    encoded_initial = base64.b64encode(json.dumps(initial).encode()).decode()
    script += "printf '%s' '" + encoded_initial + "' | base64 -d > /var/lib/stalwart-secrets/initial.json\n"
    if desired.get("mailBackup"):
        source = json.loads((secret_dir / "secret.json").read_text())["cloudflare"]["backupR2"]
        credentials.setdefault("mailBackupPassword", secrets.token_urlsafe(48))
        credential_file.write_text(json.dumps(credentials, indent=2) + "\n")
        credential_file.chmod(0o600)
        backup_env = {
            "AWS_ACCESS_KEY_ID": source["accessKeyId"],
            "AWS_SECRET_ACCESS_KEY": source["secretAccessKey"],
            "AWS_DEFAULT_REGION": "auto",
            "AWS_REGION": "auto",
            "RESTIC_REPOSITORY": "s3:" + source["endpoint"].rstrip("/") + "/" + source["bucket"] + "/mail/stalwart/restic",
            "RESTIC_PASSWORD": credentials["mailBackupPassword"],
        }
        encoded_env = base64.b64encode(("\n".join(k + "=" + json.dumps(v) for k, v in backup_env.items()) + "\n").encode()).decode()
        script += "if [ ! -e /var/lib/stalwart-secrets/backup.env ]; then\nprintf '%s' '" + encoded_env + "' | base64 -d > /var/lib/stalwart-secrets/backup.env\nfi\n"
    command = ["ssh", "-i", str(secret_dir / "server/b/operator-ed25519"), "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes", f"{server['username']}@{server['host']}", "bash -s"]
    subprocess.run(command, input=script.encode(), check=True)
    print("Stalwart admin credential staged; passwords remain in", credential_file)
    raise SystemExit(0)
