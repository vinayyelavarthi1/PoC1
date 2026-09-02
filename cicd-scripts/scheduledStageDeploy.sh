#!/bin/bash
################################################################################
# Automated Stage Deployment
#
# Usage:
#   ./cicd-scripts/scheduledStageDeploy.sh
#
# Purpose:
#   Deploy all changes merged into org/stage since the last successful Stage
#   deployment checkpoint. The checkpoint is stored as a movable git tag and is
#   updated only after validation and deployment complete successfully.
#
# Optional environment variables:
#   STAGE_BRANCH                  Stage branch to deploy. Default: org/stage
#   STAGE_CHECKPOINT_TAG          Successful deployment checkpoint tag.
#                                 Default: stage-last-successful-deployment
#   CODE_FREEZE_ACTIVE            Set to true to pause automated Stage deploys.
#   ALLOW_FREEZE_STAGE_DEPLOYMENT Set to true for an approved freeze deployment.
#
# Destructive changes:
#   Developer-authored destructive manifests are supported at:
#     manifest/destructive-changes/pre.xml
#     manifest/destructive-changes/post.xml
#
# Flow:
#   1. Fetch org/stage and resolve the checkpoint tag.
#   2. Generate a fresh SGD delta from checkpoint to org/stage HEAD.
#   3. Print generated package.xml and destructiveChanges.xml, when present.
#   4. Validate using RunRelevantTests.
#   5. Deploy using RunLocalTests.
#   6. Move the checkpoint tag to org/stage HEAD after successful deployment.
################################################################################
set -euo pipefail

STAGE_BRANCH="${STAGE_BRANCH:-org/stage}"
CHECKPOINT_TAG="${STAGE_CHECKPOINT_TAG:-stage-last-successful-deployment}"
echo "Starting automated Stage deployment for ${STAGE_BRANCH}."

echo "========== Code Freeze Check =========="
if [[ "${CODE_FREEZE_ACTIVE:-false}" == "true" && "${ALLOW_FREEZE_STAGE_DEPLOYMENT:-false}" != "true" ]]; then
  echo "Code freeze is active. Automated Stage deployment is paused."
  exit 0
fi

echo "========== Checkout Stage Branch =========="
git fetch --tags origin "+refs/heads/${STAGE_BRANCH}:refs/remotes/origin/${STAGE_BRANCH}"
git checkout --detach "origin/${STAGE_BRANCH}"
export BITBUCKET_BRANCH="${STAGE_BRANCH}"

echo "========== Resolve Deployment Checkpoint =========="
if ! git rev-parse -q --verify "refs/tags/${CHECKPOINT_TAG}" >/dev/null; then
  echo "Checkpoint tag ${CHECKPOINT_TAG} was not found."
  echo "Create it at the last successful Stage deployment commit before enabling the schedule."
  exit 1
fi

CHECKPOINT_COMMIT="$(git rev-parse "${CHECKPOINT_TAG}")"
TARGET_COMMIT="$(git rev-parse HEAD)"

echo "Last successful Stage deployment checkpoint: ${CHECKPOINT_COMMIT}"
echo "Current ${STAGE_BRANCH} commit: ${TARGET_COMMIT}"

if [[ "${CHECKPOINT_COMMIT}" == "${TARGET_COMMIT}" ]]; then
  echo "No changes found since the last successful Stage deployment."
  exit 0
fi

echo "========== Stage Changes In Scope =========="
echo "Changes included in this Stage deployment:"
git log --first-parent --reverse --pretty=format:'%h %ci %s' "${CHECKPOINT_COMMIT}..${TARGET_COMMIT}"
echo

echo "========== Generate SGD Delta =========="
mkdir -p sgd-output
SGD_ARGS=()
if [ -f .deltaignore ]; then
  SGD_ARGS+=(-i .deltaignore)
fi

sf sgd:source:delta --from "${CHECKPOINT_COMMIT}" --to "${TARGET_COMMIT}" "${SGD_ARGS[@]}" -o sgd-output --generate-delta

if [ -f sgd-output/package/package.xml ]; then
  cp sgd-output/package/package.xml ./package.xml
else
  echo "SGD did not generate package.xml."
  exit 1
fi

if [ -f sgd-output/destructiveChanges/destructiveChanges.xml ]; then
  cp sgd-output/destructiveChanges/destructiveChanges.xml ./destructiveChanges.xml
fi

echo "========== Print Generated Manifests =========="
echo "Generated package.xml:"
cat ./package.xml

if [ -f ./destructiveChanges.xml ]; then
  echo "Generated destructiveChanges.xml:"
  cat ./destructiveChanges.xml
else
  echo "destructiveChanges.xml not found"
fi

echo "========== Authenticate Target Org =========="
./cicd-scripts/authorizeOrg.sh

echo "========== Validate Stage Deployment =========="
./cicd-scripts/validateDeployment.sh

echo "========== Deploy To Stage =========="
./cicd-scripts/deploySalesforce.sh

echo "========== Update Successful Deployment Checkpoint =========="
git tag -f "${CHECKPOINT_TAG}" "${TARGET_COMMIT}"
git push origin "refs/tags/${CHECKPOINT_TAG}" --force

echo "Stage deployment completed. Updated ${CHECKPOINT_TAG} to ${TARGET_COMMIT}."
