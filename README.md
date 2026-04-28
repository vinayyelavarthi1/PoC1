# PoC1

This repo is for testing CICD implementation.

## Codex PR Review

Bitbucket pull request pipelines include a Codex review step that reviews the PR diff and posts feedback directly to the pull request.

Key files:
- `AGENTS.md` defines the basic review rules for Codex
- `cicd-scripts/codexPrReview.sh` builds the PR diff and calls the OpenAI Responses API
- `cicd-scripts/postCodexReviewComment.sh` posts the review to Bitbucket
- `bitbucket-pipelines.yaml` wires the review into pull request pipelines

Required pipeline variables:
- `OPENAI_API_KEY` or `CODEX_API_KEY`
- `BITBUCKET_SVC_USERNAME`
- `BITBUCKET_OAUTH_TOKEN`

Optional variables:
- `CODEX_MODEL`, default is `codex-mini-latest`
- `CODEX_MAX_DIFF_CHARS`

Generated artifacts:
- `pr.diff`
- `codex-review.md`
