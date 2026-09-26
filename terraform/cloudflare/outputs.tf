# Cloudflare-assigned nameservers, to set at the current registrar before
# transferring (Cloudflare Registrar requires the zone to be active first).
output "name_servers" {
  value = { for d, z in cloudflare_zone.parked : d => z.name_servers }
}
