#!/usr/bin/env python3
"""Apply the source-controlled policy before starting Stalwart's mail listeners."""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
import urllib.request


def configure(policy, initial, server, cli, config):
    password = secrets.token_urlsafe(36)
    environment = dict(os.environ, STALWART_RECOVERY_MODE="1",
        STALWART_RECOVERY_MODE_PORT="8085", STALWART_RECOVERY_ADMIN="admin:" + password,
        STALWART_URL="http://127.0.0.1:8085", STALWART_USER="admin", STALWART_PASSWORD=password)
    process = subprocess.Popen([server, "--config", config], env=environment)

    def command(arguments, payload=None):
        result = subprocess.run([cli, *arguments], env=environment,
            input="\n".join(json.dumps(item) for item in payload) if payload is not None else None,
            text=True, capture_output=True, timeout=120)
        if result.returncode:
            diagnostic = result.stderr + result.stdout
            for value in [password, initial["mailbox"]["password"],
                *(item["privateKey"].get("secret", "") for item in initial["dkim"])]:
                if value:
                    diagnostic = diagnostic.replace(value, "[redacted]").replace(json.dumps(value)[1:-1], "[redacted]")
            raise RuntimeError("Stalwart configuration failed: " + diagnostic[:1500])
        return result.stdout

    def query(object_type, fields):
        output = command(["query", object_type, "--fields", fields, "--json"]).strip()
        if not output:
            return []
        if output.startswith("["):
            return json.loads(output)
        return [json.loads(line) for line in output.splitlines()]

    try:
        for _ in range(60):
            if process.poll() is not None:
                raise RuntimeError("Stalwart exited during configuration")
            try:
                urllib.request.urlopen("http://127.0.0.1:8085/healthz/live", timeout=1).close()
                break
            except OSError:
                time.sleep(1)
        else:
            raise RuntimeError("Stalwart configuration listener did not become ready")

        domain = policy["domain"]
        operations = [{"@type": "upsert", "object": "Domain", "matchOn": ["name"],
            "value": {"mail-domain": {"name": domain, "isEnabled": True, "allowRelaying": False}}}]
        certificates = query("Certificate", "id,subjectAlternativeNames")
        certificate = next((item for item in certificates if policy["hostname"] in item.get("subjectAlternativeNames", {})), None)
        if certificate:
            operations.append({"@type": "update", "object": "Certificate", "id": certificate["id"], "value": policy["certificate"]})
            certificate_id = certificate["id"]
        else:
            operations.append({"@type": "create", "object": "Certificate", "value": {"mail-certificate": policy["certificate"]}})
            certificate_id = "#mail-certificate"
        operations.extend([
            {"@type": "update", "object": "SystemSettings", "value": {
                "defaultHostname": policy["hostname"], "defaultDomainId": "#mail-domain",
                "defaultCertificateId": certificate_id,
                "services": {"smtp": {"cleartext": False}, "imap": {"cleartext": False}, "jmap": {"cleartext": False}}}},
            {"@type": "update", "object": "Authentication", "value": {"passwordHashAlgorithm": "argon2id"}},
            {"@type": "upsert", "object": "NetworkListener", "matchOn": ["name"], "value": policy["listeners"]},
            {"@type": "update", "object": "MtaStageAuth", "value": {
                "require": {"else": "local_port != 25"},
                "saslMechanisms": {"match": {"0": {"if": "local_port != 25 && is_tls", "then": "[plain, login]"}}, "else": "[]"}}},
        ])
        accounts = query("Account", "id,name,emailAddress")
        mailbox = initial["mailbox"]
        if not any(item.get("emailAddress") == mailbox["username"] for item in accounts):
            operations.append({"@type": "create", "object": "Account", "value": {"mailbox": {
                "@type": "User", "name": mailbox["username"].split("@", 1)[0], "domainId": "#mail-domain",
                "description": "Internal mailbox", "roles": {"@type": "User"},
                "aliases": {str(index): {"name": name, "domainId": "#mail-domain", "enabled": True}
                    for index, name in enumerate(["postmaster", "abuse"])},
                "credentials": {"0": {"@type": "Password", "secret": mailbox["password"]}}}}})
        for index, forwarding in enumerate(policy["forwarding"]):
            operations.append({"@type": "upsert", "object": "MailingList", "matchOn": ["name", "domainId"],
                "value": {"forward-" + str(index): {"name": forwarding["address"].split("@", 1)[0],
                    "domainId": "#mail-domain", "recipients": {address: True for address in forwarding["destinations"]}}}})
        signatures = query("DkimSignature", "id,selector")
        for index, signature in enumerate(initial["dkim"]):
            if not any(item.get("selector") == signature["selector"] for item in signatures):
                record = dict(signature, domainId="#mail-domain")
                operations.append({"@type": "create", "object": "DkimSignature", "value": {"dkim-" + str(index): record}})
        command(["apply", "--stdin", "--quiet"], operations)
        print("Stalwart hostname, TLS, listeners, mailbox and forwarding policy applied")
    finally:
        process.terminate()
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", required=True)
    parser.add_argument("--server", required=True)
    parser.add_argument("--cli", required=True)
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    credentials = Path(os.environ["CREDENTIALS_DIRECTORY"])
    configure(json.loads(Path(args.policy).read_text()), json.loads((credentials / "initial").read_text()),
        args.server, args.cli, args.config)
