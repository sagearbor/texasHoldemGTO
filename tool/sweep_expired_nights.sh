#!/usr/bin/env bash
# Deletes every table night whose expireAt has passed (and everything under
# it: members, logs, cards), in project felt-notes-poker.
#
# Why a script: Firestore TTL policies need a billing account, and this
# project stays on the free Spark plan with billing disabled. Run it at
# least monthly (the privacy policy promises nothing is kept past 90 days;
# docs are written with expireAt = +60 days), e.g. from cron / launchd on
# the owner's Mac:
#   0 9 * * 1  /path/to/repo/tool/sweep_expired_nights.sh >> ~/feltnotes-sweep.log 2>&1
#
# Needs gcloud and the firebase CLI logged in as a project owner. Owner
# credentials bypass the security rules (which let nobody delete a night).
# --dry-run lists what would go.
set -euo pipefail
PROJECT=felt-notes-poker
DRY=${1:-}
TOKEN=$(gcloud auth print-access-token)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
IDS=$(curl -sf -X POST \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://firestore.googleapis.com/v1/projects/$PROJECT/databases/(default)/documents:runQuery" \
  -d "{\"structuredQuery\":{\"from\":[{\"collectionId\":\"nights\"}],\"where\":{\"fieldFilter\":{\"field\":{\"fieldPath\":\"expireAt\"},\"op\":\"LESS_THAN\",\"value\":{\"timestampValue\":\"$NOW\"}}},\"select\":{\"fields\":[]},\"limit\":500}}" \
  | python3 -c 'import json,sys; [print(r["document"]["name"].rsplit("/",1)[1]) for r in json.load(sys.stdin) if "document" in r]')
COUNT=$(printf '%s' "$IDS" | grep -c . || true)
echo "$(date -u +%FT%TZ) expired nights: $COUNT"
for id in $IDS; do
  if [ "$DRY" = "--dry-run" ]; then
    echo "would delete nights/$id"
  else
    firebase firestore:delete "nights/$id" --recursive --force --project "$PROJECT" >/dev/null
    echo "deleted nights/$id"
  fi
done
