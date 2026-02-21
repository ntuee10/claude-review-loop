#!/usr/bin/env bash
# Review Loop — Stop Hook
#
# Three-phase lifecycle with two-way communication:
#   Phase 1 (task):       Claude finishes work → hook runs Codex review → blocks exit
#   Phase 2 (addressing): Claude addresses review, documents disagreements →
#                           if escalations exist: hook runs Codex round 2 with counter-args → blocks for Teams arbitration
#                           otherwise: hook allows exit
#   Phase 3 (escalating): Claude Teams reviews both rounds and makes final call → hook allows exit
#
# On any error, default to allowing exit (never trap the user in a broken loop).
#
# Environment variables:
#   REVIEW_LOOP_CODEX_FLAGS  Override codex flags (default: --dangerously-bypass-approvals-and-sandbox)

LOG_FILE=".claude/review-loop.log"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

trap 'log "ERROR: hook exited via ERR trap (line $LINENO)"; printf "{\"decision\":\"approve\"}\n"; exit 0' ERR

# Consume stdin (hook input JSON) — must read to avoid broken pipe
HOOK_INPUT=$(cat)

STATE_FILE=".claude/review-loop.local.md"
ESCALATIONS_FILE=".claude/review-loop.escalations.md"

# No active loop → allow exit
if [ ! -f "$STATE_FILE" ]; then
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Parse a field from the YAML frontmatter
parse_field() {
  sed -n "s/^${1}: *//p" "$STATE_FILE" | head -1
}

ACTIVE=$(parse_field "active")
PHASE=$(parse_field "phase")
REVIEW_ID=$(parse_field "review_id")

# Not active → clean up and exit
if [ "$ACTIVE" != "true" ]; then
  rm -f "$STATE_FILE" "$ESCALATIONS_FILE"
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Validate review_id format to prevent path traversal
if ! echo "$REVIEW_ID" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$'; then
  log "ERROR: invalid review_id format: $REVIEW_ID"
  rm -f "$STATE_FILE" "$ESCALATIONS_FILE"
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Safety: if stop_hook_active is true in any blocking phase,
# something went wrong with the phase transition. Allow exit to prevent loops.
STOP_HOOK_ACTIVE=$(echo "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
if [ "$STOP_HOOK_ACTIVE" = "true" ] && { [ "$PHASE" = "task" ] || [ "$PHASE" = "addressing" ] || [ "$PHASE" = "escalating" ]; }; then
  log "WARN: stop_hook_active=true in $PHASE phase, aborting to prevent loop"
  rm -f "$STATE_FILE" "$ESCALATIONS_FILE"
  printf '{"decision":"approve"}\n'
  exit 0
fi

case "$PHASE" in
  task)
    # ── Phase 1 → 2: Run Codex for independent code review ──────────────
    REVIEW_FILE="reviews/review-${REVIEW_ID}.md"
    mkdir -p reviews

    CODEX_PROMPT="You are performing a thorough, independent code review of recent changes in this repository.

Step 1: Understand the changes
- Run git log --oneline -20 and git diff to see recent changes
- Read all modified/added files carefully

Step 2: Write your complete review to: ${REVIEW_FILE}

Your review MUST include ALL of these sections:

## Code Quality
- Code organization, modularity, and structure
- Maintainability and readability
- DRY principles and appropriate abstractions
- Naming conventions and consistency

## Test Coverage
- Tests for new/changed functionality
- Edge cases and error paths covered
- Test quality and maintainability

## Security
- Input validation and sanitization
- Authentication/authorization issues
- Injection vulnerabilities (SQL, XSS, command injection)
- Secret/credential exposure risks
- OWASP Top 10 considerations

## Documentation & Agent Harness
- AGENTS.md files in appropriate directories
- CLAUDE.md symlinks for each AGENTS.md
- Telemetry/observability instrumentation
- Type system usage and constraints
- Agent guardrails and setup for success

## UX & Design (SKIP this section entirely if the project has no browser-based UI)
- E2E workflow test coverage
- Visual design quality and consistency
- Accessibility considerations
- Responsive design (test at desktop and mobile viewports)
- If the project has a web UI, use agent-browser for E2E tests and screenshots:
  Install: npm install -g agent-browser (or: brew install agent-browser)
  Navigate the running app, test key workflows, and take screenshots to verify UX.

For each issue found, provide:
1. File path and line number
2. Severity: critical / high / medium / low
3. Category
4. Description
5. Suggested fix

Organize by severity (critical first). End with a summary: total issues, breakdown by severity, overall assessment.

IMPORTANT: Write the FULL review to ${REVIEW_FILE}. You must create that file."

    # Run codex non-interactively with telemetry logging.
    # REVIEW_LOOP_CODEX_FLAGS overrides the default flags.
    CODEX_FLAGS="${REVIEW_LOOP_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}"
    CODEX_EXIT=0
    START_TIME=$(date +%s)

    if command -v codex &> /dev/null; then
      log "Starting Codex review (flags: $CODEX_FLAGS)"
      # shellcheck disable=SC2086
      codex $CODEX_FLAGS exec "$CODEX_PROMPT" >/dev/null 2>&1 || CODEX_EXIT=$?
      ELAPSED=$(( $(date +%s) - START_TIME ))
      log "Codex finished (exit=$CODEX_EXIT, elapsed=${ELAPSED}s)"
    else
      log "WARN: codex not found, skipping independent review"
    fi

    # Transition to addressing phase
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' 's/^phase: task$/phase: addressing/' "$STATE_FILE"
    else
      sed -i 's/^phase: task$/phase: addressing/' "$STATE_FILE"
    fi

    # Build prompt for Claude based on whether the review file was created
    if [ -f "$REVIEW_FILE" ]; then
      REASON="An independent code review from Codex has been written to ${REVIEW_FILE}.

Please:
1. Read the review carefully
2. For each item, independently decide if you agree
3. For items you AGREE with: implement the fix
4. For items you DISAGREE with: briefly note why you are skipping them, AND document each disagreement in ${ESCALATIONS_FILE} (create it if it doesn't exist) using this format:

   ## Disagreement: <item title>
   **Codex suggestion:** <what Codex suggested>
   **Your counter-argument:** <why you disagree or propose an alternative>

5. Focus on critical and high severity items first
6. When done addressing all relevant items, you may stop

Use your own judgment. Do not blindly accept every suggestion. Any documented disagreements will be shared with Codex for a second-round response."
    else
      REASON="Codex was unable to complete the review (${REVIEW_FILE} not found). This may mean codex is not installed or timed out.

Please do a brief self-review of your changes covering:
- Code quality and organization
- Security vulnerabilities
- Test coverage
- Documentation (AGENTS.md)

When satisfied, you may stop."
    fi

    SYS_MSG="Review Loop [${REVIEW_ID}] — Phase 2/3: Address Codex feedback"

    jq -n --arg r "$REASON" --arg s "$SYS_MSG" \
      '{decision:"block", reason:$r, systemMessage:$s}'
    ;;

  addressing)
    # ── Phase 2 → 3 or done: Check for escalations, run Codex round 2 if needed ─
    CODEX_FLAGS="${REVIEW_LOOP_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}"

    if [ -f "$ESCALATIONS_FILE" ] && [ -s "$ESCALATIONS_FILE" ]; then
      # Two-way: feed Claude's counter-arguments back to Codex for a second-round response
      ESCALATION_REVIEW_FILE="reviews/review-${REVIEW_ID}-r2.md"

      ESCALATION_PROMPT="You are performing a follow-up code review. The implementer (Claude) addressed your initial review (reviews/review-${REVIEW_ID}.md) but disagreed with some items documented in ${ESCALATIONS_FILE}.

Please:
1. Read the original review: reviews/review-${REVIEW_ID}.md
2. Read Claude's counter-arguments: ${ESCALATIONS_FILE}
3. For each disputed item, write your updated position to: ${ESCALATION_REVIEW_FILE}
   - If you accept Claude's reasoning: mark it as RESOLVED with a brief note
   - If you still believe your original suggestion is correct: provide additional justification or a refined compromise
   - Be open to Claude's perspective — good code review is a dialogue, not a monologue

IMPORTANT: Write your complete follow-up review to ${ESCALATION_REVIEW_FILE}. You must create that file."

      ESCALATION_EXIT=0
      START_TIME=$(date +%s)

      if command -v codex &> /dev/null; then
        log "Starting Codex escalation review round 2 (flags: $CODEX_FLAGS)"
        # shellcheck disable=SC2086
        codex $CODEX_FLAGS exec "$ESCALATION_PROMPT" >/dev/null 2>&1 || ESCALATION_EXIT=$?
        ELAPSED=$(( $(date +%s) - START_TIME ))
        log "Codex escalation round 2 finished (exit=$ESCALATION_EXIT, elapsed=${ELAPSED}s)"
      else
        log "WARN: codex not found, skipping escalation review"
      fi

      # Transition to escalating phase
      if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' 's/^phase: addressing$/phase: escalating/' "$STATE_FILE"
      else
        sed -i 's/^phase: addressing$/phase: escalating/' "$STATE_FILE"
      fi

      if [ -f "$ESCALATION_REVIEW_FILE" ]; then
        REASON="There are unresolved disagreements between you and Codex. As Claude Teams, please review the full context and make a final determination:

1. Your original implementation
2. Codex's initial review: reviews/review-${REVIEW_ID}.md
3. Your counter-arguments: ${ESCALATIONS_FILE}
4. Codex's follow-up response: ${ESCALATION_REVIEW_FILE}

For each disputed item:
- If Codex has accepted your reasoning (marked RESOLVED): no action needed
- If there is still disagreement: review both perspectives and make a final, well-reasoned decision
  - If you now agree with Codex: implement the fix
  - If you still disagree: document your final reasoning clearly

When done, you may stop."
      else
        REASON="You have documented disagreements with the Codex review in ${ESCALATIONS_FILE}, but the follow-up Codex review could not be completed.

As Claude Teams, please review the disputed items in ${ESCALATIONS_FILE} and make a final judgment:
- If you believe your original reasoning was sound: document your final position
- If you want to reconsider any items: implement the fix

When done, you may stop."
      fi

      SYS_MSG="Review Loop [${REVIEW_ID}] — Phase 3/3: Claude Teams escalation arbitration"

      jq -n --arg r "$REASON" --arg s "$SYS_MSG" \
        '{decision:"block", reason:$r, systemMessage:$s}'
    else
      # No disagreements documented — review loop complete
      log "Review loop complete (review_id=$REVIEW_ID, no escalations)"
      rm -f "$STATE_FILE" "$ESCALATIONS_FILE"
      printf '{"decision":"approve"}\n'
    fi
    ;;

  escalating)
    # ── Phase 3 complete: Claude Teams made the final call. Allow exit. ──
    log "Review loop complete with escalation (review_id=$REVIEW_ID)"
    rm -f "$STATE_FILE" "$ESCALATIONS_FILE"
    printf '{"decision":"approve"}\n'
    ;;

  *)
    # Unknown phase — clean up and allow exit
    log "WARN: unknown phase '$PHASE', cleaning up"
    rm -f "$STATE_FILE" "$ESCALATIONS_FILE"
    printf '{"decision":"approve"}\n'
    ;;
esac
