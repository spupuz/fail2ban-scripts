# Fail2ban Scripts — Agent Rules

## Overview
Collection of fail2ban helper scripts for Proxmox/LXC hosts.

## Data Protection
- **NEVER commit secrets**: no `.env`, API keys, tokens, passwords.
- Always validate scripts with `bash -n script.sh` before committing.

## OmniState Memory Protocol
Use the OmniState MCP server (`omnistate`) for persistent memory:
1. `project_register` → `session_start` at session start
2. `task_add` before significant work, `task_update` to done when finished
3. `memory_remember` for decisions (project/shared scope appropriately)
4. `session_snapshot` at end

If MCP is unreachable, say so once and continue without blocking.