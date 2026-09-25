#!/usr/bin/env python3
"""One-shot move of argocd/secrets/*.sops.yaml into 1Password, for External
Secrets Operator (see argocd/README.md's "External Secrets Operator" section).

Run from anywhere on the Mac that holds the age key, signed in to the
1Password CLI as an account owner/admin (creating a vault and a service
account both need that). Steps, each skipped if already done, so it's safe
to re-run after a failure:

  1. Create the `homelab-k8s` vault.
  2. Create one Secure Note item per Kubernetes Secret, copying each value
     straight from `sops -d` into `op item create` over stdin. Values never
     touch disk, argv, or the terminal.
  3. Read every field back through its `op://` secret reference (the same
     syntax ESO resolves) and compare it to the SOPS value. Prints only
     OK/MISMATCH.
  4. Copy the SigNoz admin login (a record, not consumed by the cluster)
     into your own vault, so the cluster's token can't read it.
  5. Create a read-only service account for `homelab-k8s` and write its
     token straight into a SOPS-encrypted Secret manifest at
     argocd/secrets/onepassword-service-account.sops.yaml.

--dry-run does only the SOPS side: decrypts everything and checks every
field is non-empty, without contacting 1Password.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SECRETS = "argocd/secrets"
VAULT = "homelab-k8s"
SERVICE_ACCOUNT = "homelab-external-secrets"
TOKEN_FILE = f"{SECRETS}/onepassword-service-account.sops.yaml"

# 1Password item title -> {field label: (sops file, --extract path)}.
# Titles and labels must match the remoteRef keys in
# manifests/external-secrets-config/. `notesPlain` is the Secure Note's own
# notes field, used for the multi-line values.
ITEMS = {
    "authelia-secrets": {
        k: ("authelia.sops.yaml", f'["stringData"]["{k}"]')
        for k in (
            "session.encryption.key",
            "storage.encryption.key",
            "identity_providers.oidc.hmac.key",
            "identity_validation.reset_password.jwt.hmac.key",
        )
    },
    "authelia-users-database": {
        "notesPlain": ("authelia-users-database.sops.yaml", '["stringData"]["users_database.yml"]'),
    },
    "authelia-oidc-jwk": {
        "notesPlain": ("authelia-oidc-jwk.sops.yaml", '["stringData"]["oidc.jwk.RS256.pem"]'),
    },
    "argocd-oidc-client-secret": {
        "client-secret": (
            "argocd-oidc-client-secret.sops.yaml",
            '["configs"]["secret"]["extra"]["oidc.authelia.clientSecret"]',
        ),
    },
    # cert-manager's and external-dns's copies are the same token (checked
    # 2026-09-24), so one item serves both.
    "cloudflare-api-token": {
        "api-token": ("cloudflare-api-token.cert-manager.sops.yaml", '["stringData"]["api-token"]'),
    },
    # Same key as the one embedded in democratic-csi's driver config
    # (checked 2026-09-24); that config is now an ESO template.
    "truenas-api-key-democratic-csi": {
        "api-key": ("truenas-api-key.sops.yaml", '["stringData"]["api-key"]'),
    },
    "headlamp-oidc-client-secret": {
        "client-secret": ("headlamp-oidc-client-secret.sops.yaml", '["stringData"]["client-secret"]'),
    },
    "homepage-proxmox-credentials": {
        k: ("proxmox-api-token.homepage.sops.yaml", f'["stringData"]["{k}"]')
        for k in ("token-id", "token-secret")
    },
    "homepage-truenas-credentials": {
        "api-key": ("truenas-api-key.homepage.sops.yaml", '["stringData"]["api-key"]'),
    },
    "homepage-unifi-credentials": {
        "api-key": ("unifi-credentials.homepage.sops.yaml", '["stringData"]["api-key"]'),
    },
    "renovate-github-token": {
        "token": ("renovate-github-token.sops.yaml", '["stringData"]["token"]'),
    },
    "searxng-secret-key": {
        "secret-key": ("secret-key.searxng.sops.yaml", '["stringData"]["secret-key"]'),
    },
    "truenas-exporter-api-key": {
        "api-key": ("truenas-api-key.truenas-exporter.sops.yaml", '["stringData"]["api-key"]'),
    },
}

SIGNOZ_FILE = "signoz-admin-credentials.sops.yaml"
SIGNOZ_TITLE = "SigNoz admin (homelab)"


def run(args, stdin=None, check=True):
    return subprocess.run(args, input=stdin, capture_output=True, text=True, check=check, cwd=REPO)


def sops_value(file, path):
    value = run(["sops", "-d", "--extract", path, f"{SECRETS}/{file}"]).stdout
    if not value.strip():
        sys.exit(f"empty value: {file} {path}")
    return value


def exists(*args):
    return run(["op", *args], check=False).returncode == 0


def field_id(label):
    return re.sub(r"[^A-Za-z0-9]", "_", label)


def secure_note(title, values):
    fields = [{
        "id": "notesPlain", "type": "STRING", "purpose": "NOTES", "label": "notesPlain",
        "value": values.get("notesPlain", ""),
    }]
    fields += [
        {"id": field_id(label), "type": "CONCEALED", "label": label, "value": value}
        for label, value in values.items() if label != "notesPlain"
    ]
    return {"title": title, "category": "SECURE_NOTE", "fields": fields}


def create_item(vault, item):
    run(["op", "item", "create", "--vault", vault, "-"], stdin=json.dumps(item))


def verify(title, values):
    ok = True
    for label, expected in values.items():
        got = run(["op", "read", "--no-newline", f"op://{VAULT}/{title}/{label}"], check=False)
        match = got.returncode == 0 and got.stdout.rstrip("\n") == expected.rstrip("\n")
        print(f"  {'OK      ' if match else 'MISMATCH'} {title}/{label}")
        ok &= match
    return ok


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="decrypt and check SOPS values only")
    parser.add_argument("--personal-vault", default="Private",
                        help="where the SigNoz admin login goes (default: Private)")
    args = parser.parse_args()

    items = {
        title: {label: sops_value(f, p) for label, (f, p) in fields.items()}
        for title, fields in ITEMS.items()
    }
    signoz = {k: sops_value(SIGNOZ_FILE, f'["{k}"]') for k in ("email", "password")}
    print(f"Decrypted {sum(map(len, items.values()))} fields for {len(items)} items, plus the SigNoz login.")
    if args.dry_run:
        for title, values in items.items():
            print(f"  {title}: {', '.join(values)}")
        return

    if not exists("whoami"):
        sys.exit("1Password CLI isn't signed in. Unlock the 1Password app (CLI integration) or `eval $(op signin)`.")

    if exists("vault", "get", VAULT):
        print(f"Vault {VAULT} already exists.")
    else:
        run(["op", "vault", "create", VAULT, "--icon", "gears",
             "--description", "Read by the homelab cluster's External Secrets Operator. Nothing else goes here."])
        print(f"Created vault {VAULT}.")

    for title, values in items.items():
        if exists("item", "get", title, "--vault", VAULT):
            print(f"Item {title} already exists, leaving it alone.")
        else:
            create_item(VAULT, secure_note(title, values))
            print(f"Created item {title}.")

    print("Verifying every field through its op:// reference:")
    if not all([verify(title, values) for title, values in items.items()]):
        sys.exit("Some fields don't match their SOPS values. Fix those items (or delete them and re-run) "
                 "before going further.")

    if exists("item", "get", SIGNOZ_TITLE, "--vault", args.personal_vault):
        print(f"SigNoz login already in {args.personal_vault}.")
    else:
        create_item(args.personal_vault, {
            "title": SIGNOZ_TITLE,
            "category": "LOGIN",
            "urls": [{"href": "https://signoz.jakerobb.org", "primary": True}],
            "fields": [
                {"id": "username", "type": "STRING", "purpose": "USERNAME", "label": "username",
                 "value": signoz["email"].strip()},
                {"id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "label": "password",
                 "value": signoz["password"].strip()},
            ],
        })
        print(f"Copied the SigNoz admin login into {args.personal_vault}.")

    if (REPO / TOKEN_FILE).exists():
        print(f"{TOKEN_FILE} already exists; not creating another service account.")
        return
    token = run(["op", "service-account", "create", SERVICE_ACCOUNT,
                 "--vault", f"{VAULT}:read_items", "--raw"]).stdout.strip()
    manifest = (
        "apiVersion: v1\nkind: Secret\nmetadata:\n"
        "  name: onepassword-service-account\n  namespace: external-secrets\n"
        f"stringData:\n  token: {json.dumps(token)}\n"
    )
    # --filename-override picks up .sops.yaml's argocd/secrets/ creation
    # rule (path relative to the repo root, hence cwd=REPO in run()).
    encrypted = run(["sops", "encrypt", "--filename-override", TOKEN_FILE,
                     "--input-type", "yaml", "--output-type", "yaml"], stdin=manifest).stdout
    (REPO / TOKEN_FILE).write_text(encrypted)
    print(f"Created service account {SERVICE_ACCOUNT} (read-only on {VAULT}); token saved encrypted to {TOKEN_FILE}.")
    print("The token is only shown once by 1Password; that encrypted file is now its only copy "
          "besides the cluster. Commit it.")


if __name__ == "__main__":
    main()
