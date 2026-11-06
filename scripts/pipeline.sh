#!/usr/bin/env bash
# Mission 4 - Path B: local five-environment promotion pipeline.
#
# Usage:   ./scripts/pipeline.sh <image-tag>        e.g. ./scripts/pipeline.sh citybike:v1
# Env:     PROD_API_KEY   training-only secret injected into preprod + prod. Never hard-coded:
#                         export it first (e.g. export PROD_API_KEY=lab-secret).
#          HEALTH_TIMEOUT seconds to wait for /health on each gate (default: 30)
#
# Build once, promote the SAME image through staging -> uat -> oat -> preprod -> prod.
# Gates 1-4 run in a temporary container "citybike-gate" on host port 4174, so the live
# "citybike-prod" on port 4173 is untouched unless every earlier gate is green.
# The first failing gate stops the pipeline (set -e + explicit exit codes).
set -euo pipefail

IMAGE="${1:?usage: $0 <image-tag>   e.g. $0 citybike:v1}"
PROD_API_KEY="${PROD_API_KEY-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GATE_NAME=citybike-gate
GATE_PORT=4174
PROD_NAME=citybike-prod
PROD_PORT=4173

log()  { printf '\n\033[1;34m[pipeline]\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31m[pipeline] RED: %s\033[0m\n' "$*" >&2; }

[[ -n "$PROD_API_KEY" ]] || printf '\033[1;33m[pipeline] WARNING: PROD_API_KEY is empty - preprod/prod gates will catch this.\033[0m\n'
docker image inspect "$IMAGE" >/dev/null 2>&1 || { fail "image $IMAGE not found (build it first)"; exit 1; }

# Poll /health with a real retry loop + timeout (no fixed sleep).
wait_healthy() { # $1=url $2=container
  local url=$1 name=$2 deadline=$((SECONDS + HEALTH_TIMEOUT))
  until curl -fsS "$url/health" >/dev/null 2>&1; do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != "true" ]]; then
      fail "container $name exited before becoming healthy. Logs:"
      docker logs "$name" 2>&1 | tail -n 20 >&2 || true
      return 1
    fi
    if (( SECONDS >= deadline )); then
      fail "$url/health not ready after ${HEALTH_TIMEOUT}s. Logs:"
      docker logs "$name" 2>&1 | tail -n 20 >&2 || true
      return 1
    fi
    sleep 1
  done
}

# Gates 1-4: temporary container on 4174, always cleaned up.
run_gate() { # $1=gate-label $2=test-script, remaining args = docker run -e flags
  local label=$1 script=$2; shift 2
  log "GATE $label: starting $IMAGE as $GATE_NAME on :$GATE_PORT"
  docker rm -f "$GATE_NAME" >/dev/null 2>&1 || true                      # 1. remove leftovers
  docker run -d --name "$GATE_NAME" -p "$GATE_PORT:4173" "$@" "$IMAGE" >/dev/null   # 2. start detached
  local rc=0
  wait_healthy "http://localhost:$GATE_PORT" "$GATE_NAME" || rc=$?        # 3. poll /health
  if (( rc == 0 )); then
    TARGET_URL="http://localhost:$GATE_PORT" IMAGE_NAME="$IMAGE" \
      bash "$SCRIPTS_DIR/$script" || rc=$?                                 # 4. run gate script
  fi
  docker rm -f "$GATE_NAME" >/dev/null 2>&1 || true                      # 5. clean up
  if (( rc != 0 )); then
    fail "gate $label failed (exit $rc). Promotion stopped; later gates NOT run."
    exit "$rc"
  fi
  log "GATE $label: GREEN"
}

log "Promoting immutable image $IMAGE ($(docker image inspect -f '{{.Id}}' "$IMAGE" | cut -c1-19))"

run_gate "1/5 STAGING" test-staging.sh -e APP_ENV=staging
run_gate "2/5 UAT"     test-uat.sh     -e APP_ENV=uat
run_gate "3/5 OAT"     test-oat.sh     -e APP_ENV=oat
run_gate "4/5 PREPROD" test-preprod.sh -e APP_ENV=preprod -e PROD_API_KEY="$PROD_API_KEY"

# Gate 5: replace the live prod container on 4173 and keep it running if green.
log "GATE 5/5 PROD: deploying $IMAGE as $PROD_NAME on :$PROD_PORT"
PREVIOUS_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$PROD_NAME" 2>/dev/null || true)"
docker rm -f "$PROD_NAME" >/dev/null 2>&1 || true
docker run -d --name "$PROD_NAME" -p "$PROD_PORT:4173" \
  -e APP_ENV=production -e PROD_API_KEY="$PROD_API_KEY" "$IMAGE" >/dev/null
rc=0
wait_healthy "http://localhost:$PROD_PORT" "$PROD_NAME" || rc=$?
if (( rc == 0 )); then
  TARGET_URL="http://localhost:$PROD_PORT" IMAGE_NAME="$IMAGE" bash "$SCRIPTS_DIR/test-prod.sh" || rc=$?
fi
if (( rc != 0 )); then
  fail "gate 5/5 PROD failed (exit $rc)."
  if [[ -n "$PREVIOUS_IMAGE" && "$PREVIOUS_IMAGE" != "$IMAGE" ]]; then
    log "Rolling prod back to previous image $PREVIOUS_IMAGE"
    docker rm -f "$PROD_NAME" >/dev/null 2>&1 || true
    docker run -d --name "$PROD_NAME" -p "$PROD_PORT:4173" \
      -e APP_ENV=production -e PROD_API_KEY="$PROD_API_KEY" "$PREVIOUS_IMAGE" >/dev/null
  fi
  exit "$rc"
fi
log "GATE 5/5 PROD: GREEN"
log "ALL FIVE GATES GREEN - $IMAGE is live as $PROD_NAME on http://localhost:$PROD_PORT"
