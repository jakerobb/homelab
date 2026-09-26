# Reads CLOUDFLARE_API_TOKEN from the environment (injected by ./tf.sh from
# secrets/cloudflare-api-token.sops.yaml). Token setup: README.md.
provider "cloudflare" {}
