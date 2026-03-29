#!/usr/bin/env bash
# github-connector.sh — GitHub notifications sensor for AIE v2
# Polls GitHub notifications via `gh` CLI, emits events to the bus
# Usage: bash github-connector.sh [--dry-run]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/aie-config.sh"
aie_init

BUS="$(aie_get "paths.events_bus" "$AIE_WORKSPACE/memory/events/bus.jsonl")"
BUS_LOCK="${BUS}.lock"
STATE_FILE="$AIE_SENSOR_STATE_DIR/github.json"
mkdir -p "$(dirname "$STATE_FILE")"
DRY_RUN=""
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRY_RUN="true"; done

log() { echo "[github] $*"; }

if ! aie_bool "connectors.github.enabled"; then
  log "SKIP disabled in config"
  exit 0
fi

# Verify gh CLI is available and authenticated
if ! command -v gh &>/dev/null; then
  log "ERROR: gh CLI not found"
  exit 1
fi

if ! gh auth status &>/dev/null; then
  log "ERROR: gh CLI not authenticated"
  exit 1
fi

# Load previous state
PREV_STATE="{}"
[[ -f "$STATE_FILE" ]] && PREV_STATE=$(cat "$STATE_FILE")
LAST_CHECKED=$(echo "$PREV_STATE" | jq -r '.last_checked // "1970-01-01T00:00:00Z"')
SEEN_IDS=$(echo "$PREV_STATE" | jq -r '.seen_ids // []')

# Map notification reason → importance score
reason_importance() {
  case "$1" in
    review_requested) echo "0.85" ;;   # Someone wants your review
    assign)           echo "0.80" ;;   # Assigned to you
    mention)          echo "0.75" ;;   # Mentioned by name
    author)           echo "0.70" ;;   # Activity on your PR/issue
    comment)          echo "0.60" ;;   # Comment on subscribed thread
    state_change)     echo "0.55" ;;   # PR merged/closed/opened
    ci_activity)      echo "0.40" ;;   # CI pass/fail
    subscribed)       echo "0.35" ;;   # Watching a repo
    manual)           echo "0.35" ;;   # Manually subscribed
    *)                echo "0.30" ;;
  esac
}

# Map notification reason → human-readable event type
reason_event_type() {
  case "$1" in
    review_requested) echo "review_requested" ;;
    assign)           echo "assigned" ;;
    mention)          echo "mentioned" ;;
    author)           echo "author_activity" ;;
    comment)          echo "comment" ;;
    state_change)     echo "state_change" ;;
    ci_activity)      echo "ci_activity" ;;
    subscribed)       echo "subscribed_activity" ;;
    manual)           echo "manual_subscription" ;;
    *)                echo "notification" ;;
  esac
}

emit_event() {
  local id="$1" type="$2" importance="$3" payload="$4"
  local event
  event=$(jq -cn \
    --arg id "$id" --arg type "$type" --arg timestamp "$NOW" \
    --argjson importance "$importance" --argjson payload "$payload" \
    '{id: $id, source: "github", type: $type, timestamp: $timestamp,
      expires_at: (now + 604800 | strftime("%Y-%m-%dT%H:%M:%SZ")), importance: $importance, actionable: true,
      payload: $payload, consumed: false, consumer_watermark: null}')
  if [[ -z "$DRY_RUN" ]]; then
    ( flock -x 200; echo "$event" >> "$BUS" ) 200>"$BUS_LOCK"
    log "Emitted: $type → $id"
  else
    log "[DRY-RUN] Would emit: $type | $(echo "$payload" | jq -r '.summary // "?"')"
  fi
}

# Fetch notifications since last check
MAX_NOTIFICATIONS=$(aie_get "connectors.github.max_notifications" "50")
FILTER_REPOS=$(aie_get "connectors.github.filter_repos" "")

NOTIFICATIONS=$(gh api "/notifications?since=$LAST_CHECKED&per_page=$MAX_NOTIFICATIONS&all=false" 2>/dev/null)

if [[ -z "$NOTIFICATIONS" || "$NOTIFICATIONS" == "null" ]]; then
  log "WARN: No response from GitHub API"
  exit 0
fi

NUM=$(echo "$NOTIFICATIONS" | jq 'length' 2>/dev/null || echo 0)
if (( NUM == 0 )); then
  log "No new notifications"
  # Still update last_checked
  echo "$PREV_STATE" | jq --arg ts "$NOW" '.last_checked = $ts' > "$STATE_FILE"
  exit 0
fi

COUNT=0
NEW_SEEN_IDS="$SEEN_IDS"

for (( i=0; i<NUM; i++ )); do
  NOTIF=$(echo "$NOTIFICATIONS" | jq ".[$i]")

  NOTIF_ID=$(echo "$NOTIF" | jq -r '.id')
  REASON=$(echo "$NOTIF" | jq -r '.reason')
  UPDATED_AT=$(echo "$NOTIF" | jq -r '.updated_at')
  UNREAD=$(echo "$NOTIF" | jq -r '.unread')
  SUBJECT_TITLE=$(echo "$NOTIF" | jq -r '.subject.title')
  SUBJECT_TYPE=$(echo "$NOTIF" | jq -r '.subject.type')
  SUBJECT_URL=$(echo "$NOTIF" | jq -r '.subject.url // ""')
  REPO=$(echo "$NOTIF" | jq -r '.repository.full_name')

  # Skip if already seen (safe jq --arg to avoid injection)
  if echo "$SEEN_IDS" | jq -e --arg id "$NOTIF_ID" 'index($id)' &>/dev/null; then
    continue
  fi

  # Optional: filter by repos (safe jq --arg)
  if [[ -n "$FILTER_REPOS" && "$FILTER_REPOS" != "null" ]]; then
    if ! echo "$FILTER_REPOS" | jq -e --arg r "$REPO" 'index($r)' &>/dev/null; then
      continue
    fi
  fi

  IMPORTANCE=$(reason_importance "$REASON")
  EVENT_TYPE=$(reason_event_type "$REASON")

  # Build human-readable summary
  case "$REASON" in
    review_requested) summary="Review requested: $SUBJECT_TITLE ($REPO)" ;;
    assign)           summary="Assigned: $SUBJECT_TITLE ($REPO)" ;;
    mention)          summary="Mentioned in $SUBJECT_TYPE: $SUBJECT_TITLE ($REPO)" ;;
    author)           summary="Activity on your $SUBJECT_TYPE: $SUBJECT_TITLE ($REPO)" ;;
    comment)          summary="New comment on $SUBJECT_TYPE: $SUBJECT_TITLE ($REPO)" ;;
    state_change)     summary="$SUBJECT_TYPE state changed: $SUBJECT_TITLE ($REPO)" ;;
    ci_activity)      summary="CI: $SUBJECT_TITLE ($REPO)" ;;
    *)                summary="$REASON on $SUBJECT_TYPE: $SUBJECT_TITLE ($REPO)" ;;
  esac

  # Convert GitHub API URL to web URL for humans
  WEB_URL=""
  if [[ "$SUBJECT_URL" =~ /repos/([^/]+/[^/]+)/(pulls|issues)/([0-9]+) ]]; then
    OWNER_REPO="${BASH_REMATCH[1]}"
    URL_TYPE="${BASH_REMATCH[2]}"
    URL_NUM="${BASH_REMATCH[3]}"
    if [[ "$URL_TYPE" == "pulls" ]]; then
      WEB_URL="https://github.com/$OWNER_REPO/pull/$URL_NUM"
    else
      WEB_URL="https://github.com/$OWNER_REPO/issues/$URL_NUM"
    fi
  fi
  # Fallback: repo URL for types without PR/issue URLs (CI, releases, etc.)
  if [[ -z "$WEB_URL" && -n "$REPO" ]]; then
    WEB_URL="https://github.com/$REPO"
  fi

  payload=$(jq -cn \
    --arg repo "$REPO" \
    --arg subject "$SUBJECT_TITLE" \
    --arg subject_type "$SUBJECT_TYPE" \
    --arg reason "$REASON" \
    --arg summary "$summary" \
    --arg web_url "$WEB_URL" \
    --arg updated_at "$UPDATED_AT" \
    --arg unread "$UNREAD" \
    '{repo: $repo, subject: $subject, subject_type: $subject_type,
      reason: $reason, summary: $summary, web_url: $web_url,
      updated_at: $updated_at, unread: ($unread == "true")}')

  emit_event "github-$NOTIF_ID" "$EVENT_TYPE" "$IMPORTANCE" "$payload"
  (( COUNT++ ))

  # Track seen ID
  NEW_SEEN_IDS=$(echo "$NEW_SEEN_IDS" | jq --arg id "$NOTIF_ID" '. + [$id]')
done

# Trim seen_ids to last 200 to prevent unbounded growth
NEW_SEEN_IDS=$(echo "$NEW_SEEN_IDS" | jq '.[-200:]')

# Save state
jq -cn \
  --arg ts "$NOW" \
  --argjson seen "$NEW_SEEN_IDS" \
  '{last_checked: $ts, seen_ids: $seen}' > "$STATE_FILE"

log "GitHub connector complete. Emitted $COUNT event(s)."
