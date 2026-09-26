# Domains held but not used for anything (migrated from Hover, 2026-09). Each
# gets a zone with no web records and the standard "this domain sends no mail"
# set, so nobody can spoof mail from them:
#   - null MX (RFC 7505): accepts no mail
#   - SPF -all: no host may send as it
#   - DMARC p=reject: receivers should drop anything claiming to be from it
#   - empty wildcard DKIM key: no valid signatures exist
# To start using one, move it out of this list into its own file.
locals {
  parked_domains = toset([
    "camaro-ev.com",
    "camaroev.net",
    "camaroev.org",
    "camaroquestions.com",
    "fastodon.dev",
    "fastodon.me",
    "fbodyquestions.com",
    "firebirdquestions.com",
    "indigoapps.dev",
    "jakerobb.me",
    "modyourcamaro.com",
    "robb.online",
    "robb.software",
    "transamquestions.com",
    "yourwebsiteisterrible.com",
  ])

  parked_records = merge([
    for d in local.parked_domains : {
      "${d}/mx"    = { zone = d, name = d, type = "MX", content = ".", priority = 0 }
      "${d}/spf"   = { zone = d, name = d, type = "TXT", content = "\"v=spf1 -all\"", priority = null }
      "${d}/dmarc" = { zone = d, name = "_dmarc.${d}", type = "TXT", content = "\"v=DMARC1; p=reject;\"", priority = null }
      "${d}/dkim"  = { zone = d, name = "*._domainkey.${d}", type = "TXT", content = "\"v=DKIM1; p=\"", priority = null }
    }
  ]...)
}

resource "cloudflare_zone" "parked" {
  for_each = local.parked_domains

  account = { id = var.cloudflare_account_id }
  name    = each.value
  type    = "full"
}

resource "cloudflare_dns_record" "parked" {
  for_each = local.parked_records

  zone_id  = cloudflare_zone.parked[each.value.zone].id
  name     = each.value.name
  type     = each.value.type
  content  = each.value.content
  priority = each.value.priority
  ttl      = 1 # automatic
}
