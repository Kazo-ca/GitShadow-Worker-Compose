#!/bin/bash
set -euo pipefail

# ── Configuration (via variables d'environnement) ──
GH_TOKEN="${GH_TOKEN:?GH_TOKEN requis}"
ORG_NAME="${ORG_NAME:?ORG_NAME requis}"
RUNNER_LABELS="${RUNNER_LABELS:-tower,linux}"

MIN_RUNNERS="${MIN_RUNNERS:-2}"
MAX_RUNNERS="${MAX_RUNNERS:-10}"
MIN_IDLE="${MIN_IDLE:-1}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"

COMPOSE_FILE="${COMPOSE_FILE:-/app/docker-compose.yml}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-gitshadow-autoscale}"
RUNNER_SERVICE="${RUNNER_SERVICE:-runner}"

API_BASE="https://api.github.com/orgs/${ORG_NAME}/actions/runners"

# ── Fonctions ──

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

get_runners() {
  curl -s -f \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API_BASE}?per_page=100"
}

count_by_status() {
  local json="$1"
  local label_filter
  label_filter=$(echo "${RUNNER_LABELS}" | cut -d',' -f1)

  local total busy idle offline

  total=$(echo "$json" | jq --arg label "$label_filter" '
    [.runners[] | select(.labels[]?.name == $label and .status == "online")] | length')
  busy=$(echo "$json" | jq --arg label "$label_filter" '
    [.runners[] | select(.labels[]?.name == $label and .status == "online" and .busy == true)] | length')
  idle=$(echo "$json" | jq --arg label "$label_filter" '
    [.runners[] | select(.labels[]?.name == $label and .status == "online" and .busy == false)] | length')
  offline=$(echo "$json" | jq --arg label "$label_filter" '
    [.runners[] | select(.labels[]?.name == $label and .status == "offline")] | length')

  echo "${total} ${busy} ${idle} ${offline}"
}

current_replicas() {
  docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" \
    ps --format json "${RUNNER_SERVICE}" 2>/dev/null | jq -s 'length'
}

scale_to() {
  local target="$1"
  log "⚙️  Scaling ${RUNNER_SERVICE} → ${target} replicas"
  docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" \
    up -d --scale "${RUNNER_SERVICE}=${target}" --no-recreate "${RUNNER_SERVICE}"
}

# ── Boucle principale ──

log "🚀 Autoscaler démarré"
log "   Org: ${ORG_NAME} | Labels: ${RUNNER_LABELS}"
log "   Min: ${MIN_RUNNERS} | Max: ${MAX_RUNNERS} | Min idle: ${MIN_IDLE}"
log "   Intervalle: ${CHECK_INTERVAL}s"

while true; do
  runners_json=$(get_runners 2>/dev/null || echo '{"runners":[]}')
  read -r total busy idle offline <<< "$(count_by_status "$runners_json")"
  replicas=$(current_replicas 2>/dev/null || echo "0")

  log "📊 Status — containers: ${replicas} | online: ${total} (busy: ${busy}, idle: ${idle}) | offline: ${offline}"

  desired="${replicas}"

  # Règle 1 : Pas assez de runners idle → scale UP
  if [ "${idle}" -lt "${MIN_IDLE}" ] && [ "${replicas}" -lt "${MAX_RUNNERS}" ]; then
    needed=$((MIN_IDLE - idle))
    desired=$((replicas + needed))
    if [ "${desired}" -gt "${MAX_RUNNERS}" ]; then
      desired="${MAX_RUNNERS}"
    fi
    log "⬆️  Idle (${idle}) < min_idle (${MIN_IDLE}) → scale up +${needed}"
  fi

  # Règle 2 : Trop de runners idle → scale DOWN
  excess_idle=$((idle - MIN_IDLE))
  if [ "${excess_idle}" -gt 0 ] && [ "${replicas}" -gt "${MIN_RUNNERS}" ]; then
    desired=$((replicas - excess_idle))
    if [ "${desired}" -lt "${MIN_RUNNERS}" ]; then
      desired="${MIN_RUNNERS}"
    fi
    log "⬇️  Idle (${idle}) > min_idle (${MIN_IDLE}) → scale down -${excess_idle}"
  fi

  # Règle 3 : Jamais en dessous du minimum
  if [ "${desired}" -lt "${MIN_RUNNERS}" ]; then
    desired="${MIN_RUNNERS}"
  fi

  # Appliquer le scaling si nécessaire
  if [ "${desired}" -ne "${replicas}" ]; then
    scale_to "${desired}"
  else
    log "✅ Rien à faire"
  fi

  sleep "${CHECK_INTERVAL}"
done
