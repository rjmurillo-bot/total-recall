#!/usr/bin/env bash
# GitHub Copilot token exchange helper for Total Recall.
# Source this before any LLM-calling script.
# Exports LLM_BASE_URL, LLM_API_KEY, and OPENROUTER_API_KEY (compat)
# so all Total Recall scripts work without modification.

COPILOT_TOKEN_CACHE="/tmp/.copilot-jwt-cache"
COPILOT_GHU_TOKEN="${COPILOT_GHU_TOKEN:-$(cat ~/.config/openclaw/secrets/github_copilot_token 2>/dev/null)}"

copilot_refresh_token() {
  # Check cache (tokens last ~30min, refresh at 25min)
  if [[ -f "$COPILOT_TOKEN_CACHE" ]]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$COPILOT_TOKEN_CACHE" 2>/dev/null || echo 0) ))
    if (( age < 1500 )); then
      export LLM_API_KEY=$(jq -r '.token' "$COPILOT_TOKEN_CACHE")
      export LLM_BASE_URL=$(jq -r '.endpoints.api' "$COPILOT_TOKEN_CACHE")
      export OPENROUTER_API_KEY="$LLM_API_KEY"
      return 0
    fi
  fi

  local resp
  resp=$(curl -s --max-time 10 \
    https://api.github.com/copilot_internal/v2/token \
    -H "Authorization: token $COPILOT_GHU_TOKEN" \
    -H "Editor-Version: OpenClaw/1.0" \
    -H "Editor-Plugin-Version: 1.0")

  local jwt=$(echo "$resp" | jq -r '.token // empty')
  local api_url=$(echo "$resp" | jq -r '.endpoints.api // empty')

  if [[ -z "$jwt" ]]; then
    echo "ERROR: Copilot token exchange failed" >&2
    return 1
  fi

  echo "$resp" > "$COPILOT_TOKEN_CACHE"
  chmod 600 "$COPILOT_TOKEN_CACHE"

  export LLM_API_KEY="$jwt"
  export LLM_BASE_URL="$api_url"
  export OPENROUTER_API_KEY="$jwt"
}

# Auto-refresh on source
copilot_refresh_token
