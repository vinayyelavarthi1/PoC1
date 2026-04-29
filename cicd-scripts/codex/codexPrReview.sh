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
# - CODEX_MODEL defaults to gpt-5.1-codex-mini
# - CODEX_MAX_DIFF_CHARS defaults to 180000
# - CODEX_MAX_OUTPUT_TOKENS defaults to 6000

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
MODEL="${CODEX_MODEL:-gpt-5.1-codex-mini}"
MAX_DIFF_CHARS="${CODEX_MAX_DIFF_CHARS:-180000}"
MAX_OUTPUT_TOKENS="${CODEX_MAX_OUTPUT_TOKENS:-6000}"
API_KEY="${OPENAI_API_KEY:-${CODEX_API_KEY:-}}"
OUTPUT_DIR="output"
DIFF_FILE="$OUTPUT_DIR/pr_codex.diff"
REVIEW_FILE="$OUTPUT_DIR/codex-review.md"
OPENAI_RESPONSE_FILE="$OUTPUT_DIR/openai-response.json"

cd "$REPO_ROOT"
mkdir -p "$OUTPUT_DIR"

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

if [ -n "${OPENAI_API_KEY:-}" ]; then
  echo "Codex API key source: OPENAI_API_KEY"
elif [ -n "${CODEX_API_KEY:-}" ]; then
  echo "Codex API key source: CODEX_API_KEY"
fi

echo "Codex model: $MODEL"

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
  printf '{"summary":"No pull request diff detected.","risk":"low","verdict":"approve","findings":[]}\n' > "$REVIEW_FILE"
else
  PAYLOAD_FILE="$(mktemp)"
  trap 'rm -f "$PAYLOAD_FILE"' EXIT

  node - "$DIFF_FILE" "$PAYLOAD_FILE" "$MODEL" "$MAX_DIFF_CHARS" "$MAX_OUTPUT_TOKENS" <<'NODE'
const fs = require('fs');

const [diffPath, payloadPath, model, maxDiffCharsRaw, maxOutputTokensRaw] = process.argv.slice(2);
const maxDiffChars = Number(maxDiffCharsRaw || 180000);
const maxOutputTokens = Number(maxOutputTokensRaw || 6000);
const rulesDir = 'cicd-scripts/codex/rules';

let diff = fs.readFileSync(diffPath, 'utf8');
let truncationNote = '';

if (diff.length > maxDiffChars) {
  diff = diff.slice(0, maxDiffChars);
  truncationNote = `\n\n[Note: diff was truncated to ${maxDiffChars} characters for review. Mention this limitation if it affects confidence.]`;
}

const ruleFiles = fs.existsSync(rulesDir)
  ? fs.readdirSync(rulesDir)
      .filter(fileName => fileName.toLowerCase().endsWith('.md'))
      .sort()
  : [];

const reviewRules = ruleFiles
  .map(fileName => [
    `Rule file: ${rulesDir}/${fileName}`,
    fs.readFileSync(`${rulesDir}/${fileName}`, 'utf8').trim()
  ].join('\n'))
  .filter(Boolean)
  .join('\n\n');

const fallbackRules = [
  'Review only the provided Git diff.',
  'Focus only on Salesforce metadata best practices.',
  'Do not invent findings.',
  'Return only JSON with summary, risk, verdict, and findings.'
].join('\n');

const prompt = [
  'You are reviewing a Bitbucket pull request.',
  '',
  'Markdown review rules:',
  reviewRules || fallbackRules,
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
    'Follow the output format requested by the repository and Markdown review rules.',
    'Do not invent issues.'
  ].join(' '),
  input: prompt,
  reasoning: {
    effort: 'low'
  },
  max_output_tokens: maxOutputTokens
};

fs.writeFileSync(payloadPath, JSON.stringify(payload));
NODE

  HTTP_STATUS="$(
    curl -sS -o "$OPENAI_RESPONSE_FILE" -w "%{http_code}" \
      https://api.openai.com/v1/responses \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${API_KEY}" \
      -d @"$PAYLOAD_FILE"
  )"

  if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
    echo "OpenAI request failed with HTTP status $HTTP_STATUS"
    cat "$OPENAI_RESPONSE_FILE"
    exit 1
  fi

  node - "$OPENAI_RESPONSE_FILE" "$REVIEW_FILE" <<'NODE'
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
  if (item.type === 'text' && typeof item.text === 'string') return item.text;
  if (typeof item.output_text === 'string') return item.output_text;
  if (typeof item.text === 'string') return item.text;
  if (Array.isArray(item.content)) return item.content.map(extractText).join('');
  if (Array.isArray(item.output)) return item.output.map(extractText).join('');
  return '';
}

const text = response.output_text || extractText(response).trim();

if (!text) {
  console.error('OpenAI response did not include review text.');
  if (response.status) console.error(`Response status: ${response.status}`);
  if (response.incomplete_details) console.error(`Incomplete details: ${JSON.stringify(response.incomplete_details)}`);
  if (response.output) console.error(`Output item types: ${response.output.map(item => item.type).join(', ')}`);
  console.error(`Raw response saved to ${responsePath}`);
  process.exit(1);
}

fs.writeFileSync(outputPath, `${text.trim()}\n`);
NODE

  echo "Codex review written to $REVIEW_FILE"
fi

"$SCRIPT_DIR/postCodexReviewComment.sh" "$REVIEW_FILE"
