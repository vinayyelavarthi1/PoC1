#!/bin/bash -x
set -e

echo "Validating deployment on org: $TARGETORG"

PACKAGE_XML="package/package.xml"

# ----------------------------------------
# Exit gracefully if Salesforce delta is empty
# ----------------------------------------
if ! grep -q "<types>" "$PACKAGE_XML"; then
  echo "✅ No Salesforce metadata detected. Skipping SF validation."
  exit 0
fi

# Run Salesforce Validation
sf project deploy validate --manifest package/package.xml --test-level RunRelevantTests --verbose --ignore-warnings --target-org "$TARGETORG" --pre-destructive-changes manifest/destructive-changes/pre.xml --post-destructive-changes manifest/destructive-changes/post.xml

echo "$validateOutput"
#add output to PR
if [ ! -z "$sendPrComment" ]; then
  sfOutput=`echo "$validateOutput"`
  #post pr comment
  ./cicd-scripts/postPrComment.sh "$sfOutput" validate
fi
echo "Validation execution completed!"

# Display org info
sfdx org:display --target-org "$TARGETORG"
