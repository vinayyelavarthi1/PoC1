#!/bin/bash
#
# Post Codex Review Comment
# Posts the generated Codex markdown review to the current Bitbucket pull request.
#
# Required variables:
# - BITBUCKET_WORKSPACE
# - BITBUCKET_REPO_SLUG
# - BITBUCKET_PR_ID
# - BITBUCKET_SVC_USERNAME
# - BITBUCKET_OAUTH_TOKEN

set -euo pipefail

REVIEW_FILE="${1:-codex-review.md}"

if [ ! -f "$REVIEW_FILE" ]; then
  echo "Review file not found: $REVIEW_FILE"
  exit 1
fi

for required_var in BITBUCKET_WORKSPACE BITBUCKET_REPO_SLUG BITBUCKET_PR_ID BITBUCKET_SVC_USERNAME BITBUCKET_OAUTH_TOKEN; do
  if [ -z "${!required_var:-}" ]; then
    echo "$required_var is required to post a Bitbucket PR comment."
    exit 1
  fi
done

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to build the Bitbucket comment payload."
  exit 1
fi

PAYLOAD_FILE="$(mktemp)"
RESPONSE_FILE="$(mktemp)"
trap 'rm -f "$PAYLOAD_FILE" "$RESPONSE_FILE"' EXIT

node - "$REVIEW_FILE" "$PAYLOAD_FILE" <<'NODE'
const fs = require('fs');

const [reviewPath, payloadPath] = process.argv.slice(2);
const review = fs.readFileSync(reviewPath, 'utf8').trim();
const body = `### Codex PR Review\n\n${review || 'No significant findings.'}`;

fs.writeFileSync(payloadPath, JSON.stringify({
  content: {
    raw: body
  }
}));
NODE

HTTP_STATUS="$(
  curl -sS -o "$RESPONSE_FILE" -w "%{http_code}" \
    -X POST \
    "https://api.bitbucket.org/2.0/repositories/$BITBUCKET_WORKSPACE/$BITBUCKET_REPO_SLUG/pullrequests/$BITBUCKET_PR_ID/comments" \
    -u "$BITBUCKET_SVC_USERNAME:$BITBUCKET_OAUTH_TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$PAYLOAD_FILE"
)"

if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
  echo "Failed to post Codex PR comment. Bitbucket returned HTTP status $HTTP_STATUS"
  cat "$RESPONSE_FILE"
  exit 1
fi

echo "Codex PR comment posted."
