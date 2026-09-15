#!/bin/bash
curl -sk -H "X-API-Key: ${UNIFI_TOKEN}" \
  "https://192.168.0.1/proxy/network/api/s/default/stat/device" \
  | jq -r '.data[] | 
    select(.total_max_effective_power != null and .total_max_effective_power > 0) |
    "unifi_device_capacity,device_name=\(.name | gsub(" "; "\\ ")) poe_budget_watts=\(.total_max_effective_power)"'
