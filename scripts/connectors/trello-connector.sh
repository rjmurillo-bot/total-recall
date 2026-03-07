#!/usr/bin/env bash
# trello-connector.sh — Trello board sensor for AIE v2
# Polls configured boards for recent card activity (moves, creates, comments)
# Usage: bash trello-connector.sh [--dry-run]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/aie-config.sh"
aie_init

BUS="$(aie_get "paths.events_bus" "$AIE_WORKSPACE/memory/events/bus.jsonl")"
BUS_LOCK="${BUS}.lock"
STATE_FILE="$AIE_SENSOR_STATE_DIR/trello.json"
mkdir -p "$(dirname "$STATE_FILE")"
DRY_RUN=""
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NOW_EPOCH=$(date -u +%s)

for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRY_RUN="true"; done

log() { echo "[trello] $*"; }

if ! aie_bool "connectors.trello.enabled"; then
  log "SKIP disabled in config"
  exit 0
fi

TRELLO_KEY="$(aie_get "connectors.trello.api_key_file" "$HOME/.config/openclaw/secrets/trello_api_key")"
TRELLO_TOKEN_FILE="$(aie_get "connectors.trello.token_file" "$HOME/.config/openclaw/secrets/trello_token")"

if [[ ! -f "$TRELLO_KEY" || ! -f "$TRELLO_TOKEN_FILE" ]]; then
  log "SKIP missing Trello credentials"
  exit 0
fi

API_KEY=$(cat "$TRELLO_KEY")
API_TOKEN=$(cat "$TRELLO_TOKEN_FILE")

emit_event() {
  local id="$1" type="$2" importance="$3" payload="$4"
  local event
  event=$(jq -cn \
    --arg id "$id" --arg type "$type" --arg timestamp "$NOW" \
    --argjson importance "$importance" --argjson payload "$payload" \
    '{id: $id, source: "trello", type: $type, timestamp: $timestamp,
      expires_at: null, importance: $importance, actionable: false,
      payload: $payload, consumed: false, consumer_watermark: null}')
  if [[ -z "$DRY_RUN" ]]; then
    ( flock -x 200; echo "$event" >> "$BUS" ) 200>"$BUS_LOCK"
    log "Emitted: $type → $id"
  else
    log "[DRY-RUN] Would emit: $type | $(echo "$payload" | jq -r '.card_name // .summary // "?"')"
  fi
}

# Load previous state (last seen action dates per board)
PREV_STATE="{}"
[[ -f "$STATE_FILE" ]] && PREV_STATE=$(cat "$STATE_FILE")
NEW_STATE="$PREV_STATE"
COUNT=0

# Read board configs from aie.yaml
BOARDS_JSON=$(python3 <<'PY'
import json, os
data = json.loads(os.environ["AIE_CONFIG_JSON"])
boards = data.get("connectors", {}).get("trello", {}).get("boards", [])
print(json.dumps(boards))
PY
)

NUM_BOARDS=$(echo "$BOARDS_JSON" | jq 'length')

for (( i=0; i<NUM_BOARDS; i++ )); do
  BOARD_ID=$(echo "$BOARDS_JSON" | jq -r ".[$i].id")
  BOARD_LABEL=$(echo "$BOARDS_JSON" | jq -r ".[$i].label // \"board-$i\"")
  BOARD_IMPORTANCE=$(echo "$BOARDS_JSON" | jq -r ".[$i].importance // \"0.6\"")

  # Get last seen action date for this board
  LAST_SEEN=$(echo "$PREV_STATE" | jq -r --arg b "$BOARD_ID" '.[$b] // "1970-01-01T00:00:00.000Z"')

  # Fetch recent actions (card creates, moves, comments) since last seen
  ACTIONS=$(curl -s --max-time 15 \
    "https://api.trello.com/1/boards/$BOARD_ID/actions?key=$API_KEY&token=$API_TOKEN&filter=createCard,updateCard,commentCard&since=$LAST_SEEN&limit=25" 2>/dev/null)

  if [[ -z "$ACTIONS" || "$ACTIONS" == "null" ]]; then
    log "WARN: No response from Trello for board $BOARD_LABEL"
    continue
  fi

  NUM_ACTIONS=$(echo "$ACTIONS" | jq 'length' 2>/dev/null || echo 0)
  if (( NUM_ACTIONS == 0 )); then
    log "Board '$BOARD_LABEL': no new actions"
    continue
  fi

  NEWEST_DATE="$LAST_SEEN"

  for (( j=0; j<NUM_ACTIONS; j++ )); do
    ACTION=$(echo "$ACTIONS" | jq ".[$j]")
    ACTION_TYPE=$(echo "$ACTION" | jq -r '.type')
    ACTION_DATE=$(echo "$ACTION" | jq -r '.date')
    ACTION_ID=$(echo "$ACTION" | jq -r '.id')
    CARD_NAME=$(echo "$ACTION" | jq -r '.data.card.name // "unknown"')
    LIST_NAME=$(echo "$ACTION" | jq -r '.data.list.name // .data.listAfter.name // ""')
    LIST_BEFORE=$(echo "$ACTION" | jq -r '.data.listBefore.name // ""')
    COMMENT=$(echo "$ACTION" | jq -r '.data.text // ""' | head -c 300)

    # Map action type to event type
    case "$ACTION_TYPE" in
      createCard)   event_type="card_created" ;;
      updateCard)   event_type="card_moved" ;;
      commentCard)  event_type="card_comment" ;;
      *)            event_type="card_activity" ;;
    esac

    # Build summary
    summary=""
    case "$ACTION_TYPE" in
      createCard)   summary="New card '$CARD_NAME' in '$LIST_NAME'" ;;
      updateCard)
        if [[ -n "$LIST_BEFORE" && -n "$LIST_NAME" ]]; then
          summary="Card '$CARD_NAME' moved from '$LIST_BEFORE' to '$LIST_NAME'"
        else
          summary="Card '$CARD_NAME' updated in '$LIST_NAME'"
        fi
        ;;
      commentCard)  summary="Comment on '$CARD_NAME': ${COMMENT:0:200}" ;;
    esac

    payload=$(jq -cn \
      --arg board "$BOARD_LABEL" \
      --arg board_id "$BOARD_ID" \
      --arg card_name "$CARD_NAME" \
      --arg list "$LIST_NAME" \
      --arg list_before "$LIST_BEFORE" \
      --arg action_type "$ACTION_TYPE" \
      --arg summary "$summary" \
      --arg comment "$COMMENT" \
      '{board: $board, board_id: $board_id, card_name: $card_name,
        list: $list, list_before: $list_before, action_type: $action_type,
        summary: $summary, comment: $comment}')

    emit_event "trello-$ACTION_ID" "$event_type" "$BOARD_IMPORTANCE" "$payload"
    (( COUNT++ ))

    # Track newest action date
    if [[ "$ACTION_DATE" > "$NEWEST_DATE" ]]; then
      NEWEST_DATE="$ACTION_DATE"
    fi
  done

  NEW_STATE=$(echo "$NEW_STATE" | jq --arg b "$BOARD_ID" --arg d "$NEWEST_DATE" '.[$b] = $d')
  log "Board '$BOARD_LABEL': $NUM_ACTIONS action(s)"
done

# Save state
echo "$NEW_STATE" > "$STATE_FILE"

log "Trello connector complete. Emitted $COUNT event(s)."
