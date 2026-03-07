#!/usr/bin/env bash
# obsidian-connector.sh — Obsidian Vault sensor for AIE v2
# Watches for recently modified markdown files, emits summaries of changes
# Usage: bash obsidian-connector.sh [--dry-run]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/aie-config.sh"
aie_init

BUS="$(aie_get "paths.events_bus" "$AIE_WORKSPACE/memory/events/bus.jsonl")"
BUS_LOCK="${BUS}.lock"
STATE_FILE="$AIE_SENSOR_STATE_DIR/obsidian.json"
mkdir -p "$(dirname "$STATE_FILE")"
DRY_RUN=""
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NOW_EPOCH=$(date -u +%s)

for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRY_RUN="true"; done

log() { echo "[obsidian] $*"; }

if ! aie_bool "connectors.obsidian.enabled"; then
  log "SKIP disabled in config"
  exit 0
fi

VAULT_PATH="$(aie_get "connectors.obsidian.vault_path" "")"
LOOKBACK_MINUTES="$(aie_get "connectors.obsidian.lookback_minutes" "30")"
MAX_FILES="$(aie_get "connectors.obsidian.max_files" "10")"
IGNORE_PATTERNS="$(aie_get "connectors.obsidian.ignore_patterns" ".trash,.obsidian")"

if [[ -z "$VAULT_PATH" || ! -d "$VAULT_PATH" ]]; then
  log "SKIP vault_path not set or directory missing"
  exit 0
fi

emit_event() {
  local id="$1" type="$2" importance="$3" payload="$4"
  local event
  event=$(jq -cn \
    --arg id "$id" --arg type "$type" --arg timestamp "$NOW" \
    --argjson importance "$importance" --argjson payload "$payload" \
    '{id: $id, source: "obsidian", type: $type, timestamp: $timestamp,
      expires_at: null, importance: $importance, actionable: false,
      payload: $payload, consumed: false, consumer_watermark: null}')
  if [[ -z "$DRY_RUN" ]]; then
    ( flock -x 200; echo "$event" >> "$BUS" ) 200>"$BUS_LOCK"
    log "Emitted: $type → $id"
  else
    log "[DRY-RUN] Would emit: $type | $(echo "$payload" | jq -r '.title // .file // "?"')"
  fi
}

# Load previous state (file -> mtime map)
PREV_STATE="{}"
[[ -f "$STATE_FILE" ]] && PREV_STATE=$(cat "$STATE_FILE")
NEW_STATE="$PREV_STATE"
COUNT=0

# Build find exclusion args from ignore_patterns
FIND_EXCLUDES=()
IFS=',' read -ra PATTERNS <<< "$IGNORE_PATTERNS"
for p in "${PATTERNS[@]}"; do
  p="$(echo "$p" | xargs)"  # trim whitespace
  [[ -n "$p" ]] && FIND_EXCLUDES+=(-not -path "*/$p/*")
done

# Find recently modified .md files
while IFS= read -r filepath; do
  [[ -n "$filepath" ]] || continue
  (( COUNT >= MAX_FILES )) && break

  rel_path="${filepath#$VAULT_PATH/}"
  file_mtime=$(stat -c %Y "$filepath" 2>/dev/null || echo 0)
  file_key="obsidian-$(echo "$rel_path" | md5sum | cut -c1-12)"

  # Check if we've already seen this version
  prev_mtime=$(echo "$PREV_STATE" | jq -r --arg k "$file_key" '.[$k] // "0"')
  if [[ "$file_mtime" == "$prev_mtime" ]]; then
    continue
  fi

  # Determine importance based on path
  importance="0.5"
  if [[ "$rel_path" == *"Career"* || "$rel_path" == *"1-1s"* || "$rel_path" == *"Connects"* ]]; then
    importance="0.7"
  elif [[ "$rel_path" == *"Projects"* ]]; then
    importance="0.6"
  fi

  # Extract first 500 chars as summary (skip YAML frontmatter)
  summary=$(sed '/^---$/,/^---$/d' "$filepath" | head -c 500 | tr '\n' ' ' | sed 's/  */ /g')

  # Determine event type
  if [[ "$prev_mtime" == "0" ]]; then
    event_type="note_new"
  else
    event_type="note_modified"
  fi

  payload=$(jq -cn \
    --arg file "$rel_path" \
    --arg title "$(basename "$filepath" .md)" \
    --arg summary "$summary" \
    --arg event_type "$event_type" \
    '{file: $file, title: $title, summary: $summary, change_type: $event_type}')

  emit_event "$file_key-$(date +%s)" "$event_type" "$importance" "$payload"

  NEW_STATE=$(echo "$NEW_STATE" | jq --arg k "$file_key" --arg v "$file_mtime" '.[$k] = $v')
  (( COUNT++ ))

done < <(find "$VAULT_PATH" -name "*.md" -mmin "-$LOOKBACK_MINUTES" "${FIND_EXCLUDES[@]}" -type f 2>/dev/null | sort -t/ -k$(echo "$VAULT_PATH" | tr -cd '/' | wc -c) | head -n "$MAX_FILES")

# Save state
echo "$NEW_STATE" > "$STATE_FILE"

log "Obsidian connector complete. Emitted $COUNT event(s)."
