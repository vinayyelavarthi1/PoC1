#!/bin/bash -x
################################################################################
#  Validate Salesforce deployment using a delta package manifest
#      1. Resolve the generated package.xml file to validate
#      2. Run combined validation for the full package
#      3. Detect Omni metadata validation failures when applicable
#      4. Split the package and retry validation for metadata and Omni separately
#
#  Environment Variables:
#   - TARGETORG            : target Salesforce org alias/username
#   - OMNI_METADATA_TYPES  : space-separated metadata type names treated as Omni
#   - SPLIT_OUTPUT_DIR     : output directory for split package manifests
#   - BITBUCKET_PR_DESTINATION_BRANCH : PR target branch used to choose test level
#   - sendPrComment        : when set, posts validation output back to the PR
#
#  Author: Vinay Yelavarthi, 03/24/2026
#  Change Log:
#    03/24/2026 Vinay Add file header and function comment blocks
#    03/24/2026 Vinay Choose validation test level by PR destination branch
#
################################################################################
set -euo pipefail

echo "Validating deployment on org: $TARGETORG"

OMNI_METADATA_TYPES="${OMNI_METADATA_TYPES:-OmniDataTransform OmniIntegrationProcedure}"
SPLIT_OUTPUT_DIR="${SPLIT_OUTPUT_DIR:-package-split}"
ALL_VALIDATE_OUTPUT=""
VALIDATION_TEST_LEVEL=""

# ----------------------------------------
# Helper functions
# ----------------------------------------

############################################################
# Resolve the package.xml path from known pipeline output locations
#inputs:
# arg1 : none
resolve_package_xml() {
  local candidate

  for candidate in "package/package.xml" "./package.xml" "sgd-output/package/package.xml"; do
    if [ -f "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

############################################################
# Check whether a manifest contains any <types> entries
#inputs:
# arg1 : manifest path
has_types() {
  local manifest_path="$1"
  grep -q "<types>" "$manifest_path"
}

############################################################
# Check whether a manifest contains any configured Omni metadata types
#inputs:
# arg1 : manifest path
manifest_contains_omni_types() {
  local manifest_path="$1"
  local metadata_type

  for metadata_type in $OMNI_METADATA_TYPES; do
    if grep -q "<name>${metadata_type}</name>" "$manifest_path"; then
      return 0
    fi
  done

  return 1
}

############################################################
# Check whether validation output mentions any configured Omni metadata types
#inputs:
# arg1 : command output text
output_mentions_omni_types() {
  local command_output="$1"
  local metadata_type

  for metadata_type in $OMNI_METADATA_TYPES; do
    if [[ "$command_output" == *"$metadata_type"* ]]; then
      return 0
    fi
  done

  return 1
}

############################################################
# Append a labeled validation output block to the combined log buffer
#inputs:
# arg1 : label for the validation run
# arg2 : command output text
append_output() {
  local label="$1"
  local command_output="$2"

  ALL_VALIDATE_OUTPUT="${ALL_VALIDATE_OUTPUT}
===== ${label} =====
${command_output}
"
}

############################################################
# Determine the Salesforce validation test level from the PR target branch
#inputs:
# arg1 : none, uses BITBUCKET_PR_DESTINATION_BRANCH
resolve_validation_test_level() {
  local destination_branch="${BITBUCKET_PR_DESTINATION_BRANCH:-}"

  if [[ "$destination_branch" == "org/stage" || "$destination_branch" == "org/main" ]]; then
    echo "RunLocalTests"
  else
    echo "RunRelevantTests"
  fi
}

############################################################
# Build destructive change arguments for the validation command
#inputs:
# arg1 : include destructive changes, true/false
build_destructive_args() {
  local include_destructive="${1:-true}"
  DESTRUCTIVE_ARGS=()

  if [[ "$include_destructive" != "true" ]]; then
    return 0
  fi

  if [ -f "manifest/destructive-changes/pre.xml" ]; then
    DESTRUCTIVE_ARGS+=("--pre-destructive-changes" "manifest/destructive-changes/pre.xml")
  fi

  if [ -f "manifest/destructive-changes/post.xml" ]; then
    DESTRUCTIVE_ARGS+=("--post-destructive-changes" "manifest/destructive-changes/post.xml")
  elif [ -f "./destructiveChanges.xml" ]; then
    DESTRUCTIVE_ARGS+=("--post-destructive-changes" "./destructiveChanges.xml")
  fi
}

############################################################
# Run Salesforce validation for a given manifest and capture output
#inputs:
# arg1 : manifest path
# arg2 : validation label
# arg3 : include destructive changes, true/false
run_validation() {
  local manifest_path="$1"
  local label="$2"
  local include_destructive="${3:-true}"
  local validate_output
  local validate_status

  echo "Running validation for ${label}: ${manifest_path}"
  build_destructive_args "$include_destructive"

  set +e
  validate_output=$(
    sf project deploy validate \
      --manifest "$manifest_path" \
      --test-level "$VALIDATION_TEST_LEVEL" \
      --verbose \
      --ignore-warnings \
      --target-org "$TARGETORG" \
      "${DESTRUCTIVE_ARGS[@]}" 2>&1
  )
  validate_status=$?
  set -e

  echo "$validate_output"
  append_output "$label" "$validate_output"
  return "$validate_status"
}

VALIDATION_TEST_LEVEL="$(resolve_validation_test_level)"
echo "Using validation test level: ${VALIDATION_TEST_LEVEL} for PR destination branch: ${BITBUCKET_PR_DESTINATION_BRANCH:-N/A}"

PACKAGE_XML="$(resolve_package_xml || true)"

# ----------------------------------------
# Exit when package.xml is unavailable
# ----------------------------------------

if [ -z "${PACKAGE_XML:-}" ]; then
  echo "No package.xml file was found for validation."
  exit 1
fi

# ----------------------------------------
# Exit gracefully if Salesforce delta is empty
# ----------------------------------------

if ! has_types "$PACKAGE_XML"; then
  echo "No Salesforce metadata detected. Skipping SF validation."
  exit 0
fi

# ----------------------------------------
# Run combined Salesforce validation first
# ----------------------------------------

if run_validation "$PACKAGE_XML" "Combined Package" "true"; then
  echo "Validation execution completed!"
else
  # ----------------------------------------
  # Retry with split manifests for Omni failures
  # ----------------------------------------

  if manifest_contains_omni_types "$PACKAGE_XML" && output_mentions_omni_types "$ALL_VALIDATE_OUTPUT"; then
    echo "Combined validation failed with Omni metadata types. Splitting package for retry."

    ./cicd-scripts/splitPackageXml.sh "$PACKAGE_XML" "$SPLIT_OUTPUT_DIR"

    METADATA_PACKAGE_XML="${SPLIT_OUTPUT_DIR}/SF_Metadata.xml"
    OMNI_PACKAGE_XML="${SPLIT_OUTPUT_DIR}/SF_Omni.xml"
    SPLIT_STATUS=0

    if [ -f "$METADATA_PACKAGE_XML" ] && has_types "$METADATA_PACKAGE_XML"; then
      run_validation "$METADATA_PACKAGE_XML" "Salesforce Metadata Package" "true" || SPLIT_STATUS=1
    else
      echo "No non-Omni Salesforce metadata found after package split."
    fi

    if [ -f "$OMNI_PACKAGE_XML" ] && has_types "$OMNI_PACKAGE_XML"; then
      run_validation "$OMNI_PACKAGE_XML" "Omni Metadata Package" "false" || SPLIT_STATUS=1
    else
      echo "No Omni metadata found after package split."
    fi

    if [ "$SPLIT_STATUS" -ne 0 ]; then
      echo "Split package validation failed."
      if [ -n "${sendPrComment:-}" ]; then
        ./cicd-scripts/postPrComment.sh "$ALL_VALIDATE_OUTPUT" validate
      fi
      exit 1
    fi

    echo "Split package validation completed successfully."
  else
    # ----------------------------------------
    # Exit when combined validation fails for a non-Omni reason
    # ----------------------------------------

    echo "Combined validation failed and no Omni-specific fallback condition was met."
    if [ -n "${sendPrComment:-}" ]; then
      ./cicd-scripts/postPrComment.sh "$ALL_VALIDATE_OUTPUT" validate
    fi
    exit 1
  fi
fi

# ----------------------------------------
# Post validation output to the PR when enabled
# ----------------------------------------

if [ -n "${sendPrComment:-}" ]; then
  ./cicd-scripts/postPrComment.sh "$ALL_VALIDATE_OUTPUT" validate
fi

# ----------------------------------------
# Display org info
# ----------------------------------------

sfdx org:display --target-org "$TARGETORG"