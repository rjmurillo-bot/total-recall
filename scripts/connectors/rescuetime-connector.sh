#!/usr/bin/env bash
# rescuetime-connector.sh — RescueTime sensor for AIE v2
# Polls RescueTime Daily Summary Feed and Analytic Data API
# Emits productivity summary + top activity events
# Usage: bash rescuetime-connector.sh [--dry-run]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/aie-config.sh"
aie_init

BUS="$(aie_get "paths.events_bus" "$AIE_WORKSPACE/memory/events/bus.jsonl")"
BUS_LOCK="${BUS}.lock"
STATE_FILE="$AIE_SENSOR_STATE_DIR/rescuetime.json"
mkdir -p "$(dirname "$STATE_FILE")"
DRY_RUN=""
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TODAY=$(date +%Y-%m-%d)

for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRY_RUN="true"; done

log() { echo "[rescuetime] $*"; }

if ! aie_bool "connectors.rescuetime.enabled"; then
  log "SKIP disabled in config"
  exit 0
fi

# API key: env var, key file, or config
API_KEY="${RESCUETIME_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
  KEY_FILE="$(aie_get "connectors.rescuetime.api_key_file" "$HOME/.config/openclaw/secrets/rescuetime_api_key")"
  if [[ -f "$KEY_FILE" ]]; then
    API_KEY=$(cat "$KEY_FILE")
  fi
fi

if [[ -z "$API_KEY" ]]; then
  log "SKIP missing RescueTime API key (set RESCUETIME_API_KEY or api_key_file)"
  exit 0
fi

# Load previous state
PREV_STATE="{}"
[[ -f "$STATE_FILE" ]] && PREV_STATE=$(cat "$STATE_FILE")
LAST_SUMMARY_DATE=$(echo "$PREV_STATE" | jq -r '.last_summary_date // ""')
LAST_ACTIVITY_DATE=$(echo "$PREV_STATE" | jq -r '.last_activity_date // ""')

COUNT=0

# ── Productivity thresholds from config ──
PRODUCTIVE_THRESHOLD=$(aie_get "connectors.rescuetime.productive_hours_threshold" "4.0")
DISTRACTED_THRESHOLD=$(aie_get "connectors.rescuetime.distracted_hours_threshold" "2.0")
TOP_ACTIVITIES=$(aie_get "connectors.rescuetime.top_activities" "5")

emit_event() {
  local id="$1" type="$2" importance="$3" payload="$4"
  local event
  event=$(jq -cn \
    --arg id "$id" --arg type "$type" --arg timestamp "$NOW" \
    --argjson importance "$importance" --argjson payload "$payload" \
    '{id: $id, source: "rescuetime", type: $type, timestamp: $timestamp,
      expires_at: (now + 172800 | strftime("%Y-%m-%dT%H:%M:%SZ")),
      importance: $importance, actionable: false,
      payload: $payload, consumed: false, consumer_watermark: null}')
  if [[ -z "$DRY_RUN" ]]; then
    ( flock -x 200; echo "$event" >> "$BUS" ) 200>"$BUS_LOCK"
    log "Emitted: $type → $id"
  else
    log "[DRY-RUN] Would emit: $type | $(echo "$payload" | jq -r '.summary // "?"')"
  fi
}

# ═══════════════════════════════════════════
# 1. Daily Summary Feed
# ═══════════════════════════════════════════
log "Fetching daily summary..."
SUMMARY_JSON=$(curl -sf --max-time 15 \
  "https://www.rescuetime.com/anapi/daily_summary_feed.json?key=$API_KEY" 2>/dev/null)

if [[ -z "$SUMMARY_JSON" || "$SUMMARY_JSON" == "null" ]]; then
  log "WARN: No response from Daily Summary API"
else
  # The feed returns an array of daily summaries, most recent first
  NUM_DAYS=$(echo "$SUMMARY_JSON" | jq 'length' 2>/dev/null || echo 0)

  for (( i=0; i<NUM_DAYS && i<3; i++ )); do
    DAY=$(echo "$SUMMARY_JSON" | jq ".[$i]")
    DAY_DATE=$(echo "$DAY" | jq -r '.date')

    # Skip if already processed
    if [[ -n "$LAST_SUMMARY_DATE" && ! "$DAY_DATE" > "$LAST_SUMMARY_DATE" ]]; then
      continue
    fi

    # Extract key metrics
    TOTAL_HOURS=$(echo "$DAY" | jq -r '.total_hours // 0')
    PRODUCTIVE_HOURS=$(echo "$DAY" | jq -r '.all_productive_hours // 0')
    DISTRACTED_HOURS=$(echo "$DAY" | jq -r '.all_distracting_hours // 0')
    PRODUCTIVE_PCT=$(echo "$DAY" | jq -r '.productivity_pulse // 0')
    VERY_PRODUCTIVE_HOURS=$(echo "$DAY" | jq -r '.very_productive_hours // 0')
    VERY_DISTRACTED_HOURS=$(echo "$DAY" | jq -r '.very_distracting_hours // 0')
    NEUTRAL_HOURS=$(echo "$DAY" | jq -r '.neutral_hours // 0')
    TOP_CATEGORY=$(echo "$DAY" | jq -r '.top_category // "unknown"')
    TOP_PRODUCTIVE=$(echo "$DAY" | jq -r '.top_productive_category // "unknown"')
    TOP_DISTRACTED=$(echo "$DAY" | jq -r '.top_distracted_category // "unknown"')

    # Build summary string
    summary="RescueTime $DAY_DATE: ${TOTAL_HOURS}h tracked, ${PRODUCTIVE_HOURS}h productive (${PRODUCTIVE_PCT}% pulse), ${DISTRACTED_HOURS}h distracted"

    # Determine importance based on productivity
    importance="0.50"
    if (( $(echo "$DISTRACTED_HOURS > $DISTRACTED_THRESHOLD" | bc -l 2>/dev/null || echo 0) )); then
      importance="0.70"
      summary="$summary ⚠️ High distraction"
    fi
    if (( $(echo "$PRODUCTIVE_HOURS > $PRODUCTIVE_THRESHOLD" | bc -l 2>/dev/null || echo 0) )); then
      importance="0.55"
      summary="$summary ✅ Productive day"
    fi

    payload=$(jq -cn \
      --arg date "$DAY_DATE" \
      --arg summary "$summary" \
      --argjson total_hours "$TOTAL_HOURS" \
      --argjson productive_hours "$PRODUCTIVE_HOURS" \
      --argjson distracted_hours "$DISTRACTED_HOURS" \
      --argjson very_productive_hours "$VERY_PRODUCTIVE_HOURS" \
      --argjson very_distracted_hours "$VERY_DISTRACTED_HOURS" \
      --argjson neutral_hours "$NEUTRAL_HOURS" \
      --argjson productivity_pulse "$PRODUCTIVE_PCT" \
      --arg top_category "$TOP_CATEGORY" \
      --arg top_productive "$TOP_PRODUCTIVE" \
      --arg top_distracted "$TOP_DISTRACTED" \
      '{date: $date, summary: $summary,
        total_hours: $total_hours, productive_hours: $productive_hours,
        distracted_hours: $distracted_hours,
        very_productive_hours: $very_productive_hours,
        very_distracted_hours: $very_distracted_hours,
        neutral_hours: $neutral_hours,
        productivity_pulse: $productivity_pulse,
        top_category: $top_category,
        top_productive: $top_productive, top_distracted: $top_distracted,
        kind: "daily_summary"}')

    emit_event "rt-summary-$DAY_DATE" "productivity_summary" "$importance" "$payload"
    (( COUNT++ ))

    # Update watermark
    if [[ -z "$LAST_SUMMARY_DATE" || "$DAY_DATE" > "$LAST_SUMMARY_DATE" ]]; then
      LAST_SUMMARY_DATE="$DAY_DATE"
    fi
  done
fi

# ═══════════════════════════════════════════
# 2. Analytic Data: Top activities for today
# ═══════════════════════════════════════════
if [[ "$TODAY" != "$LAST_ACTIVITY_DATE" ]]; then
  log "Fetching today's top activities..."
  ACTIVITY_JSON=$(curl -sf --max-time 15 \
    "https://www.rescuetime.com/anapi/data?key=$API_KEY&perspective=rank&restrict_kind=activity&restrict_begin=$TODAY&restrict_end=$TODAY&format=json" 2>/dev/null)

  if [[ -n "$ACTIVITY_JSON" && "$ACTIVITY_JSON" != "null" ]]; then
    ROW_COUNT=$(echo "$ACTIVITY_JSON" | jq '.rows | length' 2>/dev/null || echo 0)

    if (( ROW_COUNT > 0 )); then
      # rows format: [rank, seconds, num_people, activity, category, productivity_score]
      ACTIVITIES=$(echo "$ACTIVITY_JSON" | jq --argjson n "$TOP_ACTIVITIES" '[.rows[:$n] | .[] | {
        activity: .[3],
        category: .[4],
        seconds: .[1],
        productivity: .[5],
        hours: ((.[1] / 3600 * 100 | floor) / 100)
      }]')

      # Build summary of top activities
      TOP_LIST=$(echo "$ACTIVITIES" | jq -r '.[] | "\(.activity) (\(.hours)h, prod=\(.productivity))"' | head -"$TOP_ACTIVITIES")

      summary="RescueTime top activities $TODAY: $(echo "$TOP_LIST" | tr '\n' '; ' | sed 's/; $//')"

      payload=$(jq -cn \
        --arg date "$TODAY" \
        --arg summary "$summary" \
        --argjson activities "$ACTIVITIES" \
        --argjson total_activities "$ROW_COUNT" \
        '{date: $date, summary: $summary,
          top_activities: $activities,
          total_tracked_activities: $total_activities,
          kind: "top_activities"}')

      emit_event "rt-activities-$TODAY" "activity_breakdown" "0.45" "$payload"
      (( COUNT++ ))

      LAST_ACTIVITY_DATE="$TODAY"
    fi
  fi
fi

# Save state
jq -cn \
  --arg sd "$LAST_SUMMARY_DATE" \
  --arg ad "$LAST_ACTIVITY_DATE" \
  '{last_summary_date: $sd, last_activity_date: $ad}' > "$STATE_FILE"

log "RescueTime connector complete. Emitted $COUNT event(s)."
