# PoC1

This repo is for testing CICD implementation.

## Codex PR Review

Bitbucket pull request pipelines include a Codex review step that reviews the PR diff and generates a markdown report.
Bitbucket pull request pipelines include a Codex review step that reviews the PR diff and posts feedback directly to the pull request.

Key files:
- `AGENTS.md` defines the basic review rules for Codex
- `cicd-scripts/codexPrReview.sh` runs the Codex PR review
- `bitbucket-pipelines.yaml` wires the review into pull request pipelines

Required pipeline variable:
- `OPENAI_API_KEY`
- `BITBUCKET_SVC_USERNAME`
- `BITBUCKET_OAUTH_TOKEN`

Optional variables:
- `CODEX_MODEL`

Generated artifacts:
- `pr.diff`

## Salesforce STAGE Deployment

Use the `Salesforce STAGE Deployment` custom Bitbucket pipeline for the scheduled Stage cadence. Configure Bitbucket schedules on `org/stage` for 8:00 AM, 12:00 PM, 4:00 PM, and 8:00 PM ET.

The pipeline uses `cicd-scripts/scheduledStageDeploy.sh`, which:
- diffs `org/stage` from the `stage-last-successful-deployment` tag to the current branch head
- builds a fresh deployment manifest with SGD delta for all changes in that checkpoint range
- validates with `cicd-scripts/validateDeployment.sh` using `RunRelevantTests`
- deploys with `cicd-scripts/deploySalesforce.sh` using `RunLocalTests`
- updates the checkpoint tag only after deployment succeeds

Before enabling the schedule, create `stage-last-successful-deployment` at the last successful Stage deployment commit. During code freeze, set `CODE_FREEZE_ACTIVE=true`; set `ALLOW_FREEZE_STAGE_DEPLOYMENT=true` only for the final approved freeze deployment run.
