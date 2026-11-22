#!/bin/sh
set -eu
umask 077
: "${BUCKET:?Set the private backup bucket}"
PGCONNECT_TIMEOUT=10
export PGCONNECT_TIMEOUT
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
IAM_TOKEN=$(curl -fsS --retry 2 --connect-timeout 5 --max-time 15 \
  -H 'Metadata-Flavor: Google' \
  http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token | jq -er .access_token)
for SERVICE in auth catalog booking; do
  PGHOST="$SERVICE-db" PGDATABASE="${SERVICE}_db" pg_dump -Fc > "$WORK/$SERVICE.dump"
  test -s "$WORK/$SERVICE.dump"
  curl -fsS --retry 2 --connect-timeout 10 --max-time 120 \
    -H "Authorization: Bearer $IAM_TOKEN" \
    --upload-file "$WORK/$SERVICE.dump" \
    "https://storage.yandexcloud.net/$BUCKET/daily/$STAMP/$SERVICE.dump"
  (cd "$WORK" && sha256sum "$SERVICE.dump") >> "$WORK/SHA256SUMS"
  printf '%s backup uploaded\n' "$SERVICE"
done
# The manifest is uploaded last: its presence marks a complete set of three dumps.
curl -fsS --retry 2 --connect-timeout 10 --max-time 30 \
  -H "Authorization: Bearer $IAM_TOKEN" \
  --upload-file "$WORK/SHA256SUMS" \
  "https://storage.yandexcloud.net/$BUCKET/daily/$STAMP/SHA256SUMS"
printf 'Complete backup: daily/%s/\n' "$STAMP"
