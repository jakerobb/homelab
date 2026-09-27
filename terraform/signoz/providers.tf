# Reads SIGNOZ_ACCESS_TOKEN from the environment (injected by ./tf.sh from
# secrets/signoz-api-key.sops.yaml). Key setup: README.md.
#
# The public hostname sits behind Authelia, except /api/v2/dashboards, which
# skips it so this provider's API-key requests get through (see the comment in
# argocd/apps/signoz/httproute.yaml). Managing anything besides dashboards here
# means opening that resource's API path in the HTTPRoute too.
provider "signoz" {
  endpoint = "https://signoz.jakerobb.org"
}
