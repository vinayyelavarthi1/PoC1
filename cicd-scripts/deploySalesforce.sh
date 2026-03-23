#!/bin/bash -x
set -e

echo "STARTING DEPLOYMENT on org: $TARGETORG"

PACKAGE_XML="package/package.xml"

# ----------------------------------------
# Exit gracefully if Salesforce delta is empty
# ----------------------------------------
if ! grep -q "<types>" "$PACKAGE_XML"; then
  echo "✅ No Salesforce metadata detected . Skipping SF deployment."
  exit 0
fi

# Run Salesforce Deployment
sf project deploy start --manifest package/package.xml --test-level RunRelevantTests --verbose --ignore-warnings --target-org "$TARGETORG" --pre-destructive-changes manifest/destructive-changes/pre.xml --post-destructive-changes manifest/destructive-changes/post.xml --ignore-conflicts

echo "Deployment execution completed successfully!"
