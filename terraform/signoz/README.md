# SigNoz (Terraform)

Provider: [`SigNoz/signoz`](https://registry.terraform.io/providers/SigNoz/signoz/latest) — pinned
version lives in `versions.tf`. Needs SigNoz v0.135.0 or newer (the v2 dashboard API).

Manages SigNoz dashboards. SigNoz itself is deployed by ArgoCD (`argocd/apps/signoz/`).

- `dashboard-temperatures.tf` — temperatures (CPU, NVMe, GPU, memory, other components),
  fan speed and throttling for every physical host: the Raspberry Pi control planes,
  rpi5-1, the MS-A2 and the Macs. Where each host's data comes from is in the file's
  header comment.

## Auth

A SigNoz **service account** named `terraform`, with the **Editor** role (enough to
create, update and delete dashboards; the provider's docs suggest Admin, which this
doesn't need). In SigNoz: Settings → Service Accounts → New Service Account, then its
Keys tab → Add Key, no expiry. The key is shown once.

Stored at `secrets/signoz-api-key.sops.yaml` — copy the `.example`, fill it in,
`sops -e -i` it. The B2 state key is shared with `terraform/proxmox`.

The provider talks to `https://signoz.jakerobb.org`. Everything there is behind
Authelia except `/api/v2/dashboards`, which skips it so the API key gets through; SigNoz
still checks the key on every request there. See `argocd/apps/signoz/httproute.yaml`,
including why only that path is open. Managing another kind of resource (alerts, say)
means opening its API path there too.

## Running this

Same as `terraform/cloudflare`: PRs touching `terraform/signoz/**` get a `plan` and
merges to `main` get an `apply`, via `.github/workflows/terraform-signoz.yml` on the
jump box's runner (see `docs/gha-terraform.md`). Manual runs use `./tf.sh` on the jump
box only.

**First apply is manual**, since the workflow refuses to apply against empty state (its
guard against a broken backend). On the jump box, after pulling `main`:

```bash
./terraform/signoz/tf.sh init
./terraform/signoz/tf.sh apply
```

## Editing a dashboard in the GUI

Terraform doesn't lock the dashboards it creates, so they can be edited in SigNoz like
any other. But the repo is the source of truth: the next apply of this stack reverts GUI
changes that haven't been copied back. To tweak one graphically:

1. Edit and save it in SigNoz.
2. Export its JSON from the dashboard's menu in SigNoz.
3. Fold the changes back into its `.tf` file. The export uses the same structure as
   the `spec` attribute, in camelCase (`timePreference` here is `time_preference`).
4. `./tf.sh plan` should show **No changes**. If it shows a diff, the `.tf` file
   doesn't match yet.
5. Merge. Until then, don't merge anything else under `terraform/signoz/`.
