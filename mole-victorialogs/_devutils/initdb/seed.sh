#!/bin/sh
# Seed the dev VictoriaLogs with test log lines, then flush so they are queryable
# immediately. Runs once (restart: "no"). The victoria-logs image is FROM scratch
# (no in-container healthcheck possible), so this script POLLS /health before
# ingesting rather than relying on a service_healthy gate.
#
# NOTE: the fixtures carry NO `_time` field, so VictoriaLogs stamps each line with
# its INGESTION time (≈ container startup). That keeps the logs "recent" so
# time-window verbs (`hits`/`stats --range`, `query --last …`) return data right
# after `up`. Re-run `docker compose up` (or restart the seeder) to refresh the
# timestamps if you are testing time-window verbs long after startup.
set -eu

echo "waiting for VictoriaLogs at ${VLOGS_URL} ..."
i=0
until curl -sf "${VLOGS_URL}/health" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then echo "timed out waiting for VictoriaLogs"; exit 1; fi
  sleep 1
done

echo "seeding VictoriaLogs at ${VLOGS_URL} ..."

# JSON-line ingestion: one JSON object per line. --data-binary preserves newlines
# (unlike -d). The explicit Content-Type is REQUIRED — curl's default
# `application/x-www-form-urlencoded` makes VictoriaLogs try to form-decode the
# body and silently store 0 rows (HTTP 200, no data). `_stream_fields` defines the
# log streams; no `_time_field` → VL uses ingestion time.
curl -sS --fail -X POST \
  -H 'Content-Type: application/stream+json' \
  --data-binary @/seed/logs.jsonl \
  "${VLOGS_URL}/insert/jsonline?_stream_fields=host,app&_msg_field=_msg"

curl -sS "${VLOGS_URL}/internal/force_flush" || true

echo "VictoriaLogs seeded."
