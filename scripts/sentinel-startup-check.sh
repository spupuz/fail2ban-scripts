#!/bin/bash
# SENTINEL FIX: Startup validation for unresolved placeholders
# Ensures config.local has been properly rendered before scripts run

# Function to check if config has unresolved placeholders
check_config_placeholders() {
  local config_file="config.local"
  local has_placeholders=false
  
  if [[ -f "$config_file" ]]; then
    # Check for any __[A-Z0-9_]*__ patterns that weren't replaced
    local placeholders
    placeholders=$(grep -cE '__[A-Z0-9_]+__' "$config_file" 2>/dev/null || echo "0")
    
    if [[ "$placeholders" -gt 0 ]]; then
      has_placeholders=true
    fi
  fi
  
  # Also check all scripts for embedded unresolved patterns
  local script_placeholders
  script_placeholders=$(grep -rlE '__[A-Z0-9_]+__' scripts/ 2>/dev/null | wc -l)
  
  if [[ "$script_placeholders" -gt 0 ]]; then
    has_placeholders=true
  fi
  
  if $has_placeholders; then
    echo "⚠️ Sentinel Warning: Unresolved placeholders detected in config or scripts."
    echo "   Run: scripts/deploy.sh to replace __[A-Z0-9_]*__ tokens with actual values."
    echo "   Without proper config, scripts may behave unexpectedly or expose secrets."
    return 1
  fi
  
  return 0
}

# Run check on startup
check_config_placeholders
