#!/bin/bash -x
set -e

echo "Validating deployment on org: $TARGETORG"

if [ -f ./package.xml ]; then
  PACKAGE_XML="./package.xml"
else
  PACKAGE_XML="package/package.xml"
fi

if [ ! -f "$PACKAGE_XML" ]; then
  echo "Package manifest not found: $PACKAGE_XML"
  exit 1
fi

# Exit if Salesforce delta is empty
if ! grep -Eq "<types>|&lt;types&gt;" "$PACKAGE_XML"; then
  echo "No Salesforce metadata detected. Skipping SF validation."
  exit 0
fi

# Run Salesforce Validation
set +e
validateOutput=$(
  sf project deploy start \
    --dry-run \
    --manifest "$PACKAGE_XML" \
    --test-level RunRelevantTests \
    --pre-destructive-changes manifest/destructive-changes/pre.xml \
    --post-destructive-changes manifest/destructive-changes/post.xml \
    --target-org "$TARGETORG" \
    --ignore-warnings \
    --wait 60 \
    --verbose 2>&1
)
validateStatus=$?
set -e

echo "$validateOutput"
#add output to PR
if [ ! -z "$sendPrComment" ]; then
  sfOutput=`echo "$validateOutput"`
  #post pr comment
  ./cicd-scripts/postPrComment.sh "$sfOutput" validate
fi
if [ "$validateStatus" -ne 0 ]; then
  exit "$validateStatus"
fi
echo "Validation execution completed!"

# Display org info
sf org display --target-org "$TARGETORG"
