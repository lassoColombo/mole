#!/bin/sh
# Seed the dev Alertmanager runtime state: two active alerts and one silence.
# Runs once (restart: "no") after the server is healthy. Uses the v2 write API
# (the plugin itself is read-only; this is just dev-fixture setup).
set -eu

echo "seeding Alertmanager at ${AM_URL} ..."

# POST /api/v2/alerts takes an ARRAY of alerts; endsAt far in the future keeps
# them firing.
curl -sS --fail -H 'Content-Type: application/json' \
  --data-binary @/seed/alerts.json \
  "${AM_URL}/api/v2/alerts"

# POST /api/v2/silences takes a single silence and returns {silenceID}.
curl -sS --fail -H 'Content-Type: application/json' \
  --data-binary @/seed/silence.json \
  "${AM_URL}/api/v2/silences"

echo ""
echo "Alertmanager seeded."
