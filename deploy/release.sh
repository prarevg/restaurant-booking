#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
TAG=${1:?Pass the commit SHA as image tag}
[[ "$TAG" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,100}$ ]]
MODE=${2:-deploy}
[[ "$MODE" = deploy || "$MODE" = --build-only ]]
# shellcheck source=/dev/null
source /etc/restaurant-booking/cloud.env
: "${REGISTRY:?Set REGISTRY}" "${NODE:?Set NODE}" "${BACKUP_BUCKET:?Set BACKUP_BUCKET}"
exec 9>/var/lock/restaurant-booking-release.lock
flock -w 30 9
if [[ -n ${DEPLOY_SHA:-} ]] && [[ "$(git rev-parse origin/main)" != "$DEPLOY_SHA" ]]; then
  echo 'Skipping a commit superseded while waiting for the deployment lock'
  exit 0
fi
bash deploy/registry-login.sh
for SERVICE in auth-service catalog-service booking-service; do
  docker build --build-arg "SERVICE=$SERVICE" --build-arg "APP_REVISION=$TAG" \
    --build-arg "GOPROXY=${GOPROXY:-https://proxy.golang.org,direct}" \
    --build-arg "GOSUMDB=${GOSUMDB:-sum.golang.org}" \
    -f backend/deploy/Dockerfile -t "$REGISTRY/$SERVICE:$TAG" backend
  docker push "$REGISTRY/$SERVICE:$TAG"
done
docker build -f deploy/frontend.Dockerfile -t "$REGISTRY/frontend:$TAG" frontend
docker push "$REGISTRY/frontend:$TAG"
docker build -f deploy/backup.Dockerfile -t "$REGISTRY/backup:$TAG" deploy
docker push "$REGISTRY/backup:$TAG"
if [[ "$MODE" = --build-only ]]; then exit 0; fi

JOB_ID=$(printf '%s' "$TAG" | sha256sum | cut -c1-16)
for SERVICE in auth catalog booking; do
  JOB="migrate-$SERVICE-$JOB_ID"
  DSN="${SERVICE^^}_DB_DSN"
  kubectl -n booking delete job "$JOB" --ignore-not-found --wait=true >/dev/null
  cat <<YAML | kubectl -n booking apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 120
  ttlSecondsAfterFinished: 86400
  template:
    spec:
      restartPolicy: Never
      imagePullSecrets: [{name: registry-pull}]
      containers:
        - name: migrate
          image: $REGISTRY/$SERVICE-service:$TAG
          envFrom:
            - secretRef: {name: $SERVICE-service}
          command: [/bin/sh, -ec]
          args:
            - 'exec /app/migrate -path /app/migrations -database "\$$DSN" up'
          resources:
            requests: {cpu: 25m, memory: 32Mi}
            limits: {memory: 256Mi}
YAML
  if ! kubectl -n booking wait --for=condition=complete "job/$JOB" --timeout=140s; then
    printf 'Migration failed for %s; application rollout stopped.\n' "$SERVICE" >&2
    exit 1
  fi
done

helm upgrade --install restaurant-booking deploy/chart -n booking \
  --set-string node="$NODE" --set-string registry="$REGISTRY" \
  --set-string imageTag="$TAG" --set applicationEnabled=true \
  --set-string tlsResolver="${TLS_RESOLVER:-letsencrypt}" \
  --set backups.enabled=true --set-string backups.bucket="$BACKUP_BUCKET" \
  --wait --timeout 5m
for URL in https://preobart.ru/ https://api.preobart.ru/docs/auth/openapi.yaml; do
  curl -fsS --retry 3 --retry-delay 3 --connect-timeout 10 --max-time 20 "$URL" -o /dev/null
done
ACTUAL=$(curl -fsS -D - -o /dev/null --connect-timeout 10 --max-time 20 https://api.preobart.ru/docs/auth/openapi.yaml | tr -d '\r' | awk 'tolower($1)=="x-app-revision:" {print $2}')
[[ "$ACTUAL" = "$TAG" ]] || { echo 'Deployed revision mismatch' >&2; exit 1; }
printf '%s\n' "$TAG" > .deployed-revision
printf 'Deployment verified: %s\n' "$TAG"
