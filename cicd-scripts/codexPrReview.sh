#!/bin/bash
#
# Script: codexPrReview.sh
# Purpose: Review the current Bitbucket pull request diff with Codex and
#          generate a markdown report for meaningful findings in changed code.
# Author: Vinay Yelavarthi
# Date: 2026-04-14
#
set -euo pipefail

REPORT_FILE="codex-pr-review.md"
DIFF_FILE="pr.diff"
PROMPT_FILE="$(mktemp)"

echo "Preparing Codex PR review"

if ! command -v codex >/dev/null 2>&1; then
  echo "Codex CLI is not available in this image." > "$REPORT_FILE"
  cat "$REPORT_FILE"
  exit 1
fi

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "OPENAI_API_KEY is not configured for this pipeline." > "$REPORT_FILE"
  cat "$REPORT_FILE"
  exit 1
fi

if [ -z "${BITBUCKET_PR_DESTINATION_BRANCH:-}" ]; then
  echo "BITBUCKET_PR_DESTINATION_BRANCH is not set. This step must run in a pull request pipeline." > "$REPORT_FILE"
  cat "$REPORT_FILE"
  exit 1
fi

FROM_BRANCH="$BITBUCKET_PR_DESTINATION_BRANCH"
if [[ "$BITBUCKET_PR_DESTINATION_BRANCH" == sprint/* ]] && [ -n "${compareToBranch:-}" ]; then
  FROM_BRANCH="$compareToBranch"
fi

echo "Fetching destination branch: $FROM_BRANCH"
git fetch origin "+refs/heads/${FROM_BRANCH}:refs/remotes/origin/${FROM_BRANCH}"

BASE_COMMIT="$(git merge-base HEAD "origin/${FROM_BRANCH}")"
echo "Base commit: $BASE_COMMIT"

git diff --unified=0 --no-color "${BASE_COMMIT}...HEAD" > "$DIFF_FILE"

if [ ! -s "$DIFF_FILE" ]; then
  cat <<'EOF' > "$REPORT_FILE"
# Codex PR Review

No diff was detected for this pull request.
EOF
  cat "$REPORT_FILE"
  exit 0
fi

cat <<'EOF' > "$PROMPT_FILE"
Review this pull request diff and identify meaningful issues in the changed code.

Follow the repository instructions in AGENTS.md.

Review only what is present in the diff.
Return markdown.
EOF

echo "Running Codex review"
PROMPT_INPUT="$(printf "%s\n\nPull request diff:\n\n" "$(cat "$PROMPT_FILE")")"
if [ -n "${CODEX_MODEL:-}" ]; then
  codex exec -m "${CODEX_MODEL}" "$(printf "%s" "$PROMPT_INPUT"; sed -n '1,3000p' "$DIFF_FILE")" > "$REPORT_FILE"
else
  codex exec "$(printf "%s" "$PROMPT_INPUT"; sed -n '1,3000p' "$DIFF_FILE")" > "$REPORT_FILE"
fi

cat "$REPORT_FILE"

if [ -n "${sendPrComment:-}" ] && [ -n "${BITBUCKET_PR_ID:-}" ] && [ -n "${BITBUCKET_SVC_USERNAME:-}" ] && [ -n "${BITBUCKET_OAUTH_TOKEN:-}" ]; then
  COMMENT_BODY="$(sed 's/"/\\"/g' "$REPORT_FILE" | tr '\n' ' ')"
  curl -X POST \
    "https://api.bitbucket.org/2.0/repositories/$BITBUCKET_WORKSPACE/$BITBUCKET_REPO_SLUG/pullrequests/$BITBUCKET_PR_ID/comments" \
    -u "$BITBUCKET_SVC_USERNAME:$BITBUCKET_OAUTH_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"content\": {\"raw\": \"Codex PR review:\n\n$COMMENT_BODY\"}}"
fi
