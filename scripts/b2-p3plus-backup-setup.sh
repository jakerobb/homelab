#!/usr/bin/env bash
# One-time setup for the temporary P3 Plus -> B2 backup (root README, step 1).
# Run this yourself on whichever machine you want to hold the B2 CLI session —
# it needs your B2 account credentials, which this script deliberately doesn't
# supply or store: `b2 account authorize` prompts interactively.
#
# This bucket and key are throwaway — deleted once the restored data on HexOS
# is verified (see root README step 5) — so this is a documented script rather
# than full Terraform, which isn't worth the state-management overhead for a
# resource with a multi-week lifespan.
set -euo pipefail

BUCKET_NAME="${BUCKET_NAME:-p3plus-archive-temp}"

# 1. Authorize the CLI against your account (prompts for keyID + applicationKey
#    from https://secure.backblaze.com/app_keys.htm — use your master/account key
#    just for this one-time setup step, not for the ongoing backup itself).
b2 account authorize

# 2. Create a private bucket (no public access, no lifecycle rules — this is
#    temporary and gets deleted manually once restore is verified).
b2 bucket create "$BUCKET_NAME" allPrivate

# 3. Create an application key scoped to ONLY this bucket, with just the
#    capabilities needed for backup + verify + eventual cleanup delete.
#    (listAllBucketNames is needed for rclone to resolve the bucket by name.)
b2 key create \
  --bucket "$BUCKET_NAME" \
  "${BUCKET_NAME}-key" \
  listAllBucketNames,listFiles,readFiles,writeFiles,deleteFiles

# ^ Copy the printed keyID and applicationKey — you'll use THESE (not your
# master account key) for `rclone config` on the machine with P3 Plus access.
# Do not commit them anywhere; they're the credential for `rclone config` below.

echo
echo "Bucket '$BUCKET_NAME' created. Now run 'rclone config' on the machine with"
echo "P3 Plus access (the Intel MBP) and create a new B2 remote using the keyID"
echo "and applicationKey printed above — NOT your master account key."
