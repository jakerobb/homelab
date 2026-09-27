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

# The records Email Routing needs, as its API specifies them for this zone
# (GET /zones/:id/email/routing/dns; the MX priorities are per-zone). Managed
# here rather than letting Cloudflare add them on enable, so the SPF record
# can also keep Google (for sending as jake@ from Gmail).
locals {
  jakerobb_dev_mx = {
    route1 = 45
    route2 = 16
    route3 = 64
  }
}

resource "cloudflare_dns_record" "jakerobb_dev_mx" {
  for_each = local.jakerobb_dev_mx

  zone_id  = cloudflare_zone.jakerobb_dev.id
  name     = "jakerobb.dev"
  type     = "MX"
  content  = "${each.key}.mx.cloudflare.net"
  priority = each.value
  ttl      = 1
}

resource "cloudflare_dns_record" "jakerobb_dev_spf" {
  zone_id = cloudflare_zone.jakerobb_dev.id
  name    = "jakerobb.dev"
  type    = "TXT"
  content = "\"v=spf1 include:_spf.mx.cloudflare.net include:_spf.google.com ~all\""
  ttl     = 1
}

# Signs mail Cloudflare forwards, so Gmail doesn't flag it.
resource "cloudflare_dns_record" "jakerobb_dev_routing_dkim" {
  zone_id = cloudflare_zone.jakerobb_dev.id
  name    = "cf2024-1._domainkey.jakerobb.dev"
  type    = "TXT"
  content = "\"v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAiweykoi+o48IOGuP7GR3X0MOExCUDY/BCRHoWBnh3rChl7WhdyCxW3jgq1daEjPPqoi7sJvdg5hEQVsgVRQP4DcnQDVjGMbASQtrY4WmB1VebF+RPJB2ECPsEDTpeiI5ZyUAwJaVX7r6bznU67g7LvFq35yIo4sdlmtZGV+i0H4cpYH9+3JJ78km4KXwaf9xUJCWF6nxeD+qG6Fyruw1Qlbds2r85U9dkNDVAS3gioCvELryh1TxKGiVTkg4wqHTyHfWsp7KD3WQHYJn0RyfJJu6YEmL77zonn7p2SRMvTMP3ZEXibnC9gz3nnhR6wcYL8Q7zXypKTMD58bTixDSJwIDAQAB\""
  ttl     = 1
}

# Turns Email Routing on. After the records, so enabling finds them in place
# instead of adding its own copies.
resource "cloudflare_email_routing_settings" "jakerobb_dev" {
  zone_id = cloudflare_zone.jakerobb_dev.id

  depends_on = [
    cloudflare_dns_record.jakerobb_dev_mx,
    cloudflare_dns_record.jakerobb_dev_spf,
    cloudflare_dns_record.jakerobb_dev_routing_dkim,
    cloudflare_email_routing_rule.jakerobb_dev_jake,
  ]
}
