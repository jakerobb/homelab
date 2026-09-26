# Cloudflare (Terraform)

Provider: [`cloudflare/cloudflare`](https://registry.terraform.io/providers/cloudflare/cloudflare/latest) — pinned version lives in `versions.tf`.

Manages the Cloudflare zones for the domains moved from Hover (2026-09). `jakerobb.org`
isn't in here: its records belong to external-dns and cert-manager (see
`argocd/README.md`), and it has its own zone-scoped token.

- `parked.tf` — domains held but unused: no web records, and a "sends no mail" record
  set so nobody can spoof mail from them.
- `jakerobb.dev` — not yet; it moves last.

## Auth

Token **`homelab-terraform`**, created in the Cloudflare dashboard (My Profile → API
Tokens → Create Token → Custom token):

| Section | Setting |
|---|---|
| Permissions | Zone · Zone · Edit |
| | Zone · DNS · Edit |
| Account Resources | Include · Jakerobb@gmail.com's Account |
| Zone Resources | Include · All zones from an account · Jakerobb@gmail.com's Account |
| Client IP Address Filtering | Is in · rpi5-1's public IP (same one Brevo allowlists) |
| TTL | none |

"All zones from an account" rather than specific zones, because the token has to be
able to create new zones. The IP filter means a leaked token is useless off the jump
box, which is the only place this runs; if the home IP changes, update it here and in
Brevo (`docs/email-alerts.md`).

Stored at `secrets/cloudflare-api-token.sops.yaml` — copy the `.example`, fill it in,
`sops -e -i` it. The B2 state key is shared with `terraform/proxmox` (same bucket,
different state key), so there's no second copy of it here.

## Running this

Same as `terraform/proxmox`: PRs touching `terraform/cloudflare/**` get a `plan` and
merges to `main` get an `apply`, via `.github/workflows/terraform-cloudflare.yml` on the
jump box's runner (see `docs/gha-terraform.md`). Manual runs use `./tf.sh` on the jump
box only.

**First apply is manual**, since the workflow refuses to apply against empty state (its
guard against a broken backend). On the jump box, after pulling the branch:

```bash
./terraform/cloudflare/tf.sh init
./terraform/cloudflare/tf.sh apply
```

## Moving a domain from Hover

Cloudflare's API can't start a registrar transfer, so the last step is by hand.

1. Add it here and apply. Cloudflare creates the zone and assigns two nameservers
   (`./tf.sh output name_servers`).
2. At Hover, set the domain's nameservers to those two. The zone goes Active in
   Cloudflare once it notices, usually within an hour.
3. At Hover, unlock the domain and get its auth code. WHOIS privacy can stay on.
4. In the Cloudflare dashboard, Domain Registration → Transfer Domains, select it,
   paste the auth code, pay (one year's renewal, added on top of the current expiry).
5. If Hover emails a transfer-out confirmation, approving it finishes the transfer
   sooner; otherwise it completes on its own in about 5 days.
