# Terraform via GitHub Actions

`terraform/proxmox` is planned on every pull request that touches it and applied on
merge to `main`, by [`.github/workflows/terraform-proxmox.yml`](../.github/workflows/terraform-proxmox.yml).
Set up 2026-09-24.

## How it works

- **Runner:** a self-hosted GitHub Actions runner on the jump box (currently rpi5-1),
  label `homelab-jumpbox`, running as the `systemd` service installed by
  [`scripts/gha-runner/setup-runner.sh`](../scripts/gha-runner/setup-runner.sh). It lives
  there because it's the only always-on host that can reach the Proxmox API, and
  *not* in the cluster (ARC) because this Terraform manages the VMs the cluster's
  workers run on — an in-cluster runner could be killed by its own apply, and
  couldn't fix a broken cluster.
- **Isolation:** the runner runs as a dedicated `gha-runner` system user — no sudo,
  not in the `docker` group, and `jakerobb`'s home (talosconfig, kubeconfig, the
  master age key) is `0700`. It has its own age key, added as a second recipient on
  **only** the `terraform/**/secrets` rule in [`.sops.yaml`](../.sops.yaml), so CI can
  decrypt the Proxmox token and B2 state key and nothing else.
- **Tools:** jobs use the host's `terraform` and `sops` (`/usr/local/bin`) rather than
  downloading their own, so CI and manual runs always use the same Terraform version
  — state written by a newer Terraform can't be read by an older one. Upgrade them
  on the jump box by hand, as before.
- **State:** remote, in the private B2 bucket `jakerobb-homelab-tfstate`
  (`proxmox/terraform.tfstate`) via B2's S3-compatible API — see
  [`terraform/proxmox/backend.tf`](../terraform/proxmox/backend.tf). B2 keeps every
  overwritten version of the file, which is the state history.
- **Locking:** B2 doesn't support the conditional writes Terraform's S3 lockfile needs
  ([hashicorp/terraform#37143](https://github.com/hashicorp/terraform/issues/37143)),
  so [`tf.sh`](../terraform/proxmox/tf.sh) takes a host-level `flock` instead. That's
  only a real lock as long as **every run happens on the jump box** — don't run
  `tf.sh` from a Mac against this backend.
- **Public repo safety:** fork PRs never reach the runner. The plan job only runs for
  PRs from branches in this repo (Renovate's included), and the repo requires
  approval before workflows from outside contributors run at all. Workflow logs are
  public; Terraform redacts sensitive values, but don't add anything that prints
  secrets.
- **Empty-state guard:** the apply job refuses to run if the remote state is empty,
  since that means a broken/unmigrated backend, and applying would try to create
  duplicates of every existing VM.

## One-time setup

Do this **before merging** the PR that adds `backend.tf` — merging triggers an apply.

1. **B2 bucket + scoped key.** With the B2 CLI and the master key (or the B2 web
   console, same settings):

   ```bash
   b2 bucket create --default-server-side-encryption SSE-B2 jakerobb-homelab-tfstate allPrivate
   b2 key create --bucket jakerobb-homelab-tfstate terraform-state listBuckets,listFiles,readFiles,writeFiles
   ```

   No `deleteFiles`: overwriting state in B2 creates a new version rather than
   deleting, so Terraform doesn't need it, and without it a leaked key can't erase
   the state history. No lifecycle rule — keep all versions (the file is ~20KB).

2. **Encrypt the state key** (on the Mac): copy
   `terraform/proxmox/secrets/b2-state-backend.yaml.example` to
   `b2-state-backend.sops.yaml`, fill in the keyID/applicationKey from step 1, then
   `sops -e -i terraform/proxmox/secrets/b2-state-backend.sops.yaml`.

3. **Install the runner** (on the jump box, from the repo checkout on this branch). Get
   a registration token on the Mac with
   `gh api -X POST repos/jakerobb/homelab/actions/runners/registration-token --jq .token`,
   then run `sudo ./scripts/gha-runner/setup-runner.sh` and paste it when prompted.
   The script ends by printing the runner's age public key.

4. **Add the runner as a SOPS recipient** (on the Mac): put that public key in
   `.sops.yaml`'s terraform rule (replacing the commented placeholder), then re-encrypt
   both Terraform secrets for the new recipient list:

   ```bash
   sops updatekeys -y terraform/proxmox/secrets/proxmox-api-token.sops.yaml
   sops updatekeys -y terraform/proxmox/secrets/b2-state-backend.sops.yaml
   ```

   Commit and push to the branch.

5. **Migrate state** (on the jump box, after pulling the branch):

   ```bash
   cp terraform/proxmox/terraform.tfstate ~/terraform.tfstate.pre-b2-backup
   ./terraform/proxmox/tf.sh init -migrate-state
   ./terraform/proxmox/tf.sh plan
   ```

   Answer `yes` to copy the existing state. The plan must say **No changes**. Then
   delete the now-unused local `terraform/proxmox/terraform.tfstate*` files so nothing
   picks them up by mistake (the backup in `~` stays).

6. **Require approval for outside contributors' workflows** (Settings → Actions →
   General → "Approval for running fork pull request workflows from contributors" →
   *Require approval for all external contributors*), or:

   ```bash
   gh api -X PUT repos/jakerobb/homelab/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors
   ```

7. **Open the PR.** The `plan` job should run on the jump box and report **No changes**.
   Merging then runs `apply`, which should also be a no-op. Switch the jump box's
   checkout back to `main` afterward.

## Day to day

- Change `terraform/proxmox/**` in a PR → read the plan in the job summary → merge →
  apply runs. A failed apply can be retried with "Re-run jobs", or by running the
  workflow manually (`workflow_dispatch`) on `main`.
- Manual runs on the jump box still work exactly as before (`./tf.sh plan` etc.) and
  share the same lock and state.
- The runner updates itself. Re-running `setup-runner.sh` is safe at any point; it
  skips anything already done.

## Moving the jump box to new hardware

The runner's registration (`/opt/actions-runner/.runner`, `.credentials`), its
service unit and its age key all live on the jump box's disk, so moving the NVMe to a
different Pi brings the runner along with no re-registration and no `.sops.yaml`
change. After the move, just confirm it shows as *Idle* under Settings → Actions →
Runners.

To rebuild the runner from scratch instead (new disk, lost key): remove the old runner
under Settings → Actions → Runners, run `setup-runner.sh` again, replace the old
runner public key in `.sops.yaml` with the new one, and `sops updatekeys` both files
(step 4). Nothing else depends on that key.
