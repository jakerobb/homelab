# Email Routing for jakerobb.dev, replacing Hover's jake@ -> Gmail forward
# (2026-09-26). Same single address as Hover had; no catch-all.
#
# The destination address needs a one-time verification: Cloudflare emails it
# a link when this is first applied, and the rule won't deliver until it's
# clicked.
resource "cloudflare_email_routing_address" "gmail" {
  account_id = var.cloudflare_account_id
  email      = "jakerobb@gmail.com"
}

resource "cloudflare_email_routing_rule" "jakerobb_dev_jake" {
  zone_id = cloudflare_zone.jakerobb_dev.id
  name    = "jake@ to Gmail"
  enabled = true

  matchers = [{
    type  = "literal"
    field = "to"
    value = "jake@jakerobb.dev"
  }]

  actions = [{
    type  = "forward"
    value = [cloudflare_email_routing_address.gmail.email]
  }]
}

# Email Routing's MX and DKIM records (route1-3.mx.cloudflare.net, and
# cf2024-1._domainkey) were first created here, but enabling routing locks
# them: the API rejects any change, even a no-op, with "This record is managed
# by Email Routing" (code 1046). So they're Cloudflare's now, and these blocks
# drop them from state without deleting them. On a rebuild, enabling routing
# adds them itself.
removed {
  from = cloudflare_dns_record.jakerobb_dev_mx
  lifecycle {
    destroy = false
  }
}

removed {
  from = cloudflare_dns_record.jakerobb_dev_routing_dkim
  lifecycle {
    destroy = false
  }
}

# SPF isn't locked, so it stays here, to keep Google in it (for sending as
# jake@ from Gmail). Enabling routing accepts it because it already includes
# Cloudflare's.
resource "cloudflare_dns_record" "jakerobb_dev_spf" {
  zone_id = cloudflare_zone.jakerobb_dev.id
  name    = "jakerobb.dev"
  type    = "TXT"
  content = "\"v=spf1 include:_spf.mx.cloudflare.net include:_spf.google.com ~all\""
  ttl     = 1
}

# Turns Email Routing on. Routing was already enabled once directly through
# the API (provider 5.25.0 crashed creating this; 5.26.0 fixed it), and
# enabling again is a no-op.
resource "cloudflare_email_routing_settings" "jakerobb_dev" {
  zone_id = cloudflare_zone.jakerobb_dev.id

  depends_on = [
    cloudflare_dns_record.jakerobb_dev_spf,
    cloudflare_email_routing_rule.jakerobb_dev_jake,
  ]
}
