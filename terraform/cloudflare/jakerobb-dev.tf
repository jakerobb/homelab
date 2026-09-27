# jakerobb.dev — personal website, moved from Hover 2026-09-26. The site and
# its apps run on Linode (LKE) for now; see todo/FUTURE.md "Linode workload
# migration". Records copied from Hover's DNS, minus the dead SendGrid ones.
# DNS-only (not proxied), same as it was at Hover.
locals {
  jakerobb_dev_records = {
    "root-a"    = { name = "jakerobb.dev", type = "A", content = "172.236.121.244" }
    "root-aaaa" = { name = "jakerobb.dev", type = "AAAA", content = "2600:3c06:1::acec:79f4" }
    "wild-a"    = { name = "*.jakerobb.dev", type = "A", content = "172.236.121.244" }
    "wild-aaaa" = { name = "*.jakerobb.dev", type = "AAAA", content = "2600:3c06:1::acec:79f4" }
    "beta-a"    = { name = "beta.jakerobb.dev", type = "A", content = "172.236.121.244" }
    "beta-aaaa" = { name = "beta.jakerobb.dev", type = "AAAA", content = "2600:3c06:1::acec:79f4" }
    "ci-a"      = { name = "ci.jakerobb.dev", type = "A", content = "162.216.16.151" }
    "ci-aaaa"   = { name = "ci.jakerobb.dev", type = "AAAA", content = "2600:3c03::f03c:92ff:fe98:28f9" }
    "job-a"     = { name = "job.jakerobb.dev", type = "A", content = "162.216.16.151" }
    "job-aaaa"  = { name = "job.jakerobb.dev", type = "AAAA", content = "2600:3c03::f03c:92ff:fe98:28f9" }
    "db-a"      = { name = "db.jakerobb.dev", type = "A", content = "172.233.211.22" }
    "db-aaaa"   = { name = "db.jakerobb.dev", type = "AAAA", content = "2600:3c06::f03c:92ff:fe98:7e2" }
    "acme-pg"   = { name = "_acme-challenge.postgres.jakerobb.dev", type = "CNAME", content = "_acme-challenge.postgres.jakerobb.org" }
  }
}

resource "cloudflare_zone" "jakerobb_dev" {
  account = { id = var.cloudflare_account_id }
  name    = "jakerobb.dev"
  type    = "full"
}

resource "cloudflare_dns_record" "jakerobb_dev" {
  for_each = local.jakerobb_dev_records

  zone_id = cloudflare_zone.jakerobb_dev.id
  name    = each.value.name
  type    = each.value.type
  content = each.value.content
  proxied = false
  ttl     = 1 # automatic
}
