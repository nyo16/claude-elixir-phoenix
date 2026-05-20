#!/usr/bin/env bash
# PreToolUse hook: block dangerous Bash operations before execution.
# Emits permissionDecision: "deny" via JSON output and includes
# `additionalContext` so the safer alternative survives into Claude's next
# turn (CC 2.1.110+ preserves additionalContext on blocked tool calls).
#
# Elixir-specific branches self-gate on mix.exs presence (see PR #55,
# "gate hooks on mix.exs to fix cross-project bleed"). The git force-push
# block is intentionally global and stays ungated.

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[[ "$TOOL" == "Bash" ]] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -n "$COMMAND" ]] || exit 0

proj="${CLAUDE_PROJECT_DIR:-$PWD}"
is_elixir=0
[ -f "$proj/mix.exs" ] && is_elixir=1

emit_block() {
  local reason="$1"
  local ctx="$2"
  jq -nc \
    --arg reason "$reason" \
    --arg ctx "$ctx" \
    '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason,
        additionalContext: $ctx
      }
    }'
  exit 0
}

# Elixir-only: destructive Ecto operations
if [[ "$is_elixir" == 1 ]] && echo "$COMMAND" | grep -qE 'mix ecto\.(reset|drop)'; then
  emit_block \
"BLOCKED: Destructive database operation detected.
mix ecto.reset/drop will destroy all data. If intentional, run manually
outside Claude Code. Safer alternatives:
- mix ecto.rollback --step 1 (undo last migration)
- mix ecto.migrate (apply pending migrations)" \
"The user's previous Bash call ('mix ecto.reset' / 'mix ecto.drop') was blocked by the elixir-phoenix plugin to prevent data loss. Prefer 'mix ecto.rollback --step 1' to undo the last migration, 'mix ecto.migrate' to apply pending ones, or author a corrective migration with 'mix ecto.gen.migration <name>'. Do not retry the reset/drop unless the user explicitly asks again."
fi

# Global: force-push (intentionally not gated on mix.exs)
if echo "$COMMAND" | grep -qE 'git push.*(--force|-f)\b'; then
  emit_block \
"BLOCKED: Force push detected — this rewrites remote history.
If intentional, run manually outside Claude Code.
Safer alternative: git push --force-with-lease" \
"The user's previous 'git push --force' / 'git push -f' was blocked by the elixir-phoenix plugin. Use 'git push --force-with-lease' which refuses to clobber unseen commits. Only the user should run an unguarded force-push (via '!' prefix in their terminal). Do not retry."
fi

# Elixir-only: production env warning
if [[ "$is_elixir" == 1 ]] && echo "$COMMAND" | grep -qE 'MIX_ENV=prod mix'; then
  emit_block \
"WARNING: MIX_ENV=prod detected. This runs in production mode.
If building a release, this is expected. Otherwise, reconsider." \
"The user's previous command used 'MIX_ENV=prod' and was blocked by the elixir-phoenix plugin. This is only appropriate when building releases ('mix release', 'mix phx.gen.release'). For local development omit MIX_ENV or use 'MIX_ENV=dev'/'MIX_ENV=test'. Confirm release intent with the user before retrying."
fi

exit 0
