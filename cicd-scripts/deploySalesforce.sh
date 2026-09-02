#!/bin/bash -x
set -e

echo "STARTING DEPLOYMENT on org: $TARGETORG"

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
  echo "No Salesforce metadata detected. Skipping SF Deployment."
  exit 0
fi

# Run Salesforce Deployment
sf project deploy start \
  --manifest "$PACKAGE_XML" \
  --test-level RunLocalTests \
  --pre-destructive-changes manifest/destructive-changes/pre.xml \
  --post-destructive-changes manifest/destructive-changes/post.xml \
  --target-org "$TARGETORG" \
  --ignore-warnings \
  --wait 60 \
  --verbose \
  --ignore-conflicts

echo "Deployment execution completed successfully!"
