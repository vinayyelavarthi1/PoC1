#!/bin/bash
#
# Codex PR Review
# Builds the Bitbucket pull request diff, sends it to OpenAI for review,
# saves the markdown result, and posts the review back to the pull request.
#
# Required variables:
# - OPENAI_API_KEY or CODEX_API_KEY
# - BITBUCKET_PR_ID
# - BITBUCKET_PR_DESTINATION_BRANCH
#
# Optional variables:
# - CODEX_MODEL defaults to codex-mini-latest
# - CODEX_MAX_DIFF_CHARS defaults to 180000

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
MODEL="${CODEX_MODEL:-codex-mini-latest}"
MAX_DIFF_CHARS="${CODEX_MAX_DIFF_CHARS:-180000}"
API_KEY="${OPENAI_API_KEY:-${CODEX_API_KEY:-}}"
DIFF_FILE="pr.diff"
REVIEW_FILE="codex-review.md"

cd "$REPO_ROOT"

if [ -z "${BITBUCKET_PR_ID:-}" ]; then
  echo "BITBUCKET_PR_ID is not set. Codex PR review only runs for pull request pipelines."
  exit 0
fi

if [ -z "${BITBUCKET_PR_DESTINATION_BRANCH:-}" ]; then
  echo "BITBUCKET_PR_DESTINATION_BRANCH is required to build the PR diff."
  exit 1
fi

if [ -z "$API_KEY" ]; then
  echo "OPENAI_API_KEY or CODEX_API_KEY is required."
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to build and parse OpenAI JSON payloads."
  exit 1
fi

DESTINATION_BRANCH="$BITBUCKET_PR_DESTINATION_BRANCH"
DESTINATION_REF="origin/$DESTINATION_BRANCH"

echo "Fetching destination branch: $DESTINATION_BRANCH"
git fetch origin "+refs/heads/${DESTINATION_BRANCH}:refs/remotes/origin/${DESTINATION_BRANCH}"

BASE_COMMIT="$(git merge-base HEAD "$DESTINATION_REF")"

echo "Generating PR diff from $BASE_COMMIT to HEAD"
git diff --no-ext-diff --unified=80 "$BASE_COMMIT"...HEAD > "$DIFF_FILE"

if [ ! -s "$DIFF_FILE" ]; then
  echo "No pull request diff detected."
  printf "No significant findings.\n" > "$REVIEW_FILE"
else
  PAYLOAD_FILE="$(mktemp)"
  RESPONSE_FILE="$(mktemp)"
  trap 'rm -f "$PAYLOAD_FILE" "$RESPONSE_FILE"' EXIT

  node - "$DIFF_FILE" "$PAYLOAD_FILE" "$MODEL" "$MAX_DIFF_CHARS" <<'NODE'
const fs = require('fs');

const [diffPath, payloadPath, model, maxDiffCharsRaw] = process.argv.slice(2);
const maxDiffChars = Number(maxDiffCharsRaw || 180000);
const reviewRulesPath = 'AGENTS.md';

let diff = fs.readFileSync(diffPath, 'utf8');
let truncationNote = '';

if (diff.length > maxDiffChars) {
  diff = diff.slice(0, maxDiffChars);
  truncationNote = `\n\n[Note: diff was truncated to ${maxDiffChars} characters for review. Mention this limitation if it affects confidence.]`;
}

const reviewRules = fs.existsSync(reviewRulesPath)
  ? fs.readFileSync(reviewRulesPath, 'utf8')
  : [
      'Review only the pull request diff.',
      'Focus on meaningful issues in the changed code.',
      'If there is no real issue, respond with `No significant findings.`',
      'Return markdown.'
    ].join('\n');

const prompt = [
  'You are reviewing a Bitbucket pull request.',
  '',
  'Repository review instructions:',
  reviewRules,
  '',
  'Pull request diff:',
  '```diff',
  diff,
  '```',
  truncationNote
].join('\n');

const payload = {
  model,
  instructions: [
    'You are Codex performing a concise pull request review.',
    'Only review the provided diff.',
    'Lead with findings ordered by severity.',
    'Each finding should include the file and line or hunk context when possible.',
    'Do not invent issues. If there are no significant findings, output exactly: No significant findings.'
  ].join(' '),
  input: prompt,
  max_output_tokens: 2000
};

fs.writeFileSync(payloadPath, JSON.stringify(payload));
NODE

  HTTP_STATUS="$(
    curl -sS -o "$RESPONSE_FILE" -w "%{http_code}" \
      https://api.openai.com/v1/responses \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${API_KEY}" \
      -d @"$PAYLOAD_FILE"
  )"

  if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
    echo "OpenAI request failed with HTTP status $HTTP_STATUS"
    cat "$RESPONSE_FILE"
    exit 1
  fi

  node - "$RESPONSE_FILE" "$REVIEW_FILE" <<'NODE'
const fs = require('fs');

const [responsePath, outputPath] = process.argv.slice(2);
const response = JSON.parse(fs.readFileSync(responsePath, 'utf8'));

if (response.error) {
  console.error(response.error.message || JSON.stringify(response.error));
  process.exit(1);
}

function extractText(item) {
  if (!item) return '';
  if (typeof item === 'string') return item;
  if (item.type === 'output_text' && typeof item.text === 'string') return item.text;
  if (Array.isArray(item.content)) return item.content.map(extractText).join('');
  if (Array.isArray(item.output)) return item.output.map(extractText).join('');
  return '';
}

const text = response.output_text || extractText(response).trim();

if (!text) {
  console.error('OpenAI response did not include review text.');
  process.exit(1);
}

fs.writeFileSync(outputPath, `${text.trim()}\n`);
NODE

  echo "Codex review written to $REVIEW_FILE"
fi

"$SCRIPT_DIR/postCodexReviewComment.sh" "$REVIEW_FILE"
