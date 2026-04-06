#!/bin/bash
set -euo pipefail

# ── Configuration (via variables d'environnement) ──
GH_TOKEN="${GH_TOKEN:?GH_TOKEN requis}"
ORG_NAME="${ORG_NAME:?ORG_NAME requis}"
RUNNER_PREFIX="${RUNNER_PREFIX:-worker-shadow}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_LABELS="${RUNNER_LABELS:-tower,linux}"

MIN_RUNNERS="${MIN_RUNNERS:-2}"
MAX_RUNNERS="${MAX_RUNNERS:-10}"
MIN_IDLE="${MIN_IDLE:-1}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"

COMPOSE_PROJECT="${COMPOSE_PROJECT:-gitshadow-autoscale-dood}"
RUNNER_IMAGE="myoung34/github-runner:latest"
RUNNER_NETWORK="${COMPOSE_PROJECT}_default"
WORKDIR_BASE="/tmp/runner"

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

# Liste les containers runners gérés par cet autoscaler
list_runner_containers() {
  docker ps -a --filter "label=managed-by=${COMPOSE_PROJECT}" --format '{{.Names}}' 2>/dev/null | sort
}

count_runner_containers() {
  local containers
  containers=$(list_runner_containers)
  if [ -z "$containers" ]; then
    echo 0
  else
    echo "$containers" | wc -l | tr -d ' '
  fi
}

# Trouve le prochain numéro libre pour un runner
next_runner_id() {
  local max_id=0
  for name in $(list_runner_containers); do
    local id
    id=$(echo "$name" | grep -oE '[0-9]+$' || echo 0)
    if [ "$id" -gt "$max_id" ]; then
      max_id="$id"
    fi
  done
  echo $((max_id + 1))
}

# Crée un nouveau runner avec son propre workdir isolé
create_runner() {
  local id
  id=$(next_runner_id)
  local name="${COMPOSE_PROJECT}-runner-${id}"
  local workdir="${WORKDIR_BASE}/${name}"

  log "🟢 Création runner: ${name} (workdir: ${workdir})"

  # Créer le répertoire de travail sur le host
  mkdir -p "${workdir}"

  docker run -d \
    --name "${name}" \
    --label "managed-by=${COMPOSE_PROJECT}" \
    --network "${RUNNER_NETWORK}" \
    --restart unless-stopped \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${workdir}:${workdir}" \
    -e RUNNER_SCOPE=org \
    -e ORG_NAME="${ORG_NAME}" \
    -e RUNNER_NAME_PREFIX="${RUNNER_PREFIX}" \
    -e RUNNER_GROUP="${RUNNER_GROUP}" \
    -e RANDOM_RUNNER_SUFFIX=true \
    -e "LABELS=${RUNNER_LABELS}" \
    -e ACCESS_TOKEN="${GH_TOKEN}" \
    -e RUNNER_WORKDIR="${workdir}" \
    -e GIT_CONFIG_PARAMETERS="'url.http://x-access-token:${GH_TOKEN}@git-proxy:8080/github.com/.insteadOf=https://github.com/'" \
    "${RUNNER_IMAGE}" > /dev/null
}

# Supprime un runner idle (le dernier créé qui n'est pas busy)
remove_idle_runner() {
  # On prend le dernier container runner (le plus récent)
  local name
  name=$(list_runner_containers | tail -1)
  if [ -z "$name" ]; then
    return 1
  fi

  log "🔴 Suppression runner: ${name}"
  docker stop "${name}" > /dev/null 2>&1 || true
  docker rm -f "${name}" > /dev/null 2>&1 || true

  # Nettoyage du workdir
  local workdir="${WORKDIR_BASE}/${name}"
  rm -rf "${workdir}" 2>/dev/null || true
}

# ── Boucle principale ──

log "🚀 Autoscaler DooD démarré"
log "   Org: ${ORG_NAME} | Labels: ${RUNNER_LABELS}"
log "   Min: ${MIN_RUNNERS} | Max: ${MAX_RUNNERS} | Min idle: ${MIN_IDLE}"
log "   Intervalle: ${CHECK_INTERVAL}s"

# S'assurer que le réseau existe
docker network inspect "${RUNNER_NETWORK}" > /dev/null 2>&1 || \
  docker network create "${RUNNER_NETWORK}" > /dev/null 2>&1 || true

# Démarrage initial : créer les runners minimum
current=$(count_runner_containers)
if [ "${current}" -lt "${MIN_RUNNERS}" ]; then
  needed=$((MIN_RUNNERS - current))
  log "🏗️  Démarrage initial: création de ${needed} runners"
  for i in $(seq 1 "${needed}"); do
    create_runner
  done
fi

while true; do
  runners_json=$(get_runners 2>/dev/null || echo '{"runners":[]}')
  read -r total busy idle offline <<< "$(count_by_status "$runners_json")"
  current=$(count_runner_containers)

  log "📊 Status — containers: ${current} | online: ${total} (busy: ${busy}, idle: ${idle}) | offline: ${offline}"

  desired="${current}"

  # Règle 1 : Pas assez de runners idle → scale UP
  if [ "${idle}" -lt "${MIN_IDLE}" ] && [ "${current}" -lt "${MAX_RUNNERS}" ]; then
    needed=$((MIN_IDLE - idle))
    desired=$((current + needed))
    if [ "${desired}" -gt "${MAX_RUNNERS}" ]; then
      desired="${MAX_RUNNERS}"
    fi
    log "⬆️  Idle (${idle}) < min_idle (${MIN_IDLE}) → scale up +$((desired - current))"
    for i in $(seq 1 $((desired - current))); do
      create_runner
    done
  fi

  # Règle 2 : Trop de runners idle → scale DOWN
  excess_idle=$((idle - MIN_IDLE))
  if [ "${excess_idle}" -gt 0 ] && [ "${current}" -gt "${MIN_RUNNERS}" ]; then
    to_remove="${excess_idle}"
    if [ $((current - to_remove)) -lt "${MIN_RUNNERS}" ]; then
      to_remove=$((current - MIN_RUNNERS))
    fi
    if [ "${to_remove}" -gt 0 ]; then
      log "⬇️  Idle (${idle}) > min_idle (${MIN_IDLE}) → scale down -${to_remove}"
      for i in $(seq 1 "${to_remove}"); do
        remove_idle_runner
      done
    fi
  fi

  # Règle 3 : S'assurer qu'on est au minimum
  current=$(count_runner_containers)
  if [ "${current}" -lt "${MIN_RUNNERS}" ]; then
    needed=$((MIN_RUNNERS - current))
    log "⚠️  En dessous du minimum → création de ${needed} runners"
    for i in $(seq 1 "${needed}"); do
      create_runner
    done
  fi

  sleep "${CHECK_INTERVAL}"
done
