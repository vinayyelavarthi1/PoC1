# PoC1

This repo is for testing CICD implementation.

## Codex PR Review

Bitbucket pull request pipelines include a Codex review step that reviews the PR diff and generates a markdown report.

Key files:
- `AGENTS.md` defines the basic review rules for Codex
- `cicd-scripts/codexPrReview.sh` runs the Codex PR review
- `bitbucket-pipelines.yaml` wires the review into pull request pipelines

Required pipeline variable:
- `OPENAI_API_KEY`

Optional variables:
- `CODEX_MODEL`
- `sendPrComment`
- `BITBUCKET_SVC_USERNAME`
- `BITBUCKET_OAUTH_TOKEN`

Generated artifacts:
- `codex-pr-review.md`
- `pr.diff`
