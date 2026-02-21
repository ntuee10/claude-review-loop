# review-loop Plugin — Agent Guidelines

## What this is

A Claude Code plugin that creates a two-phase review loop:
1. Claude implements a task
2. Codex independently reviews the changes
3. Claude addresses the review feedback

## Conventions

- Shell scripts must work on both macOS and Linux (handle `sed -i` differences)
- The stop hook MUST always produce valid JSON to stdout — never let non-JSON text leak
- Fail-open: on any error, approve exit rather than trapping the user
- State lives in `.claude/review-loop.local.md` — always clean up on exit
- Review ID format: `YYYYMMDD-HHMMSS-hexhex` — validate before using in paths
- Codex stdout/stderr is redirected away from hook stdout to prevent JSON corruption
- Telemetry goes to `.claude/review-loop.log` — structured, timestamped lines

## Security constraints

- Review IDs are validated against `^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$` to prevent path traversal
- Codex flags are configurable via `REVIEW_LOOP_CODEX_FLAGS` env var
- The OpenAI API key for Codex can be supplied via `REVIEW_LOOP_OPENAI_API_KEY`; it is exported as `OPENAI_API_KEY` only for the duration of the codex invocation and is never stored in state files or logs
- No secrets or credentials are stored in state files

## Testing

- After modifying stop-hook.sh, test all three paths: no-state, task→addressing, addressing→approve
- Verify JSON output with `jq .` for each path
- Test with codex unavailable (should fall back to self-review prompt)
- Test with malformed state files (should fail-open)
