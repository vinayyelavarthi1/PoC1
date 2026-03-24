#!/bin/bash
################################################################################
#  Split package.xml into Salesforce metadata and Omni metadata manifests
#      1. Read a source package.xml file
#      2. Identify each <types> block by metadata type name
#      3. Separate Omni metadata types from standard Salesforce metadata
#      4. Output two manifests for retry validation/deployment scenarios
#
#  Arguments:
#   - arg1 {packageXmlPath} : source package.xml path
#   - arg2 {outputDir}      : directory where split manifests will be written
#
#  Environment Variables:
#   - OMNI_METADATA_TYPES   : space-separated metadata type names treated as Omni
#
#  Author: Vinay Yelavarthi, 03/21/2026
#  Change Log:
#    03/21/2026 Vinay Add file header and function comment blocks
#
################################################################################
set -euo pipefail

SOURCE_PACKAGE_XML="${1:-package/package.xml}"
OUTPUT_DIR="${2:-package-split}"
OMNI_METADATA_TYPES="${OMNI_METADATA_TYPES:-OmniDataTransform OmniIntegrationProcedure}"

############################################################
# Check whether a metadata type should be treated as Omni
#inputs:
# arg1 : metadata type name from a package.xml <name> entry
contains_omni_type() {
  local metadata_type="$1"
  local omni_type

  for omni_type in $OMNI_METADATA_TYPES; do
    if [ "$omni_type" = "$metadata_type" ]; then
      return 0
    fi
  done

  return 1
}

############################################################
# Extract the package.xml API version from the source manifest
#inputs:
# arg1 : none, uses SOURCE_PACKAGE_XML
extract_version() {
  sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "$SOURCE_PACKAGE_XML" | tail -1
}

############################################################
# Write a complete package.xml file from a manifest body and version
#inputs:
# arg1 : output file path
# arg2 : manifest body containing one or more <types> blocks
# arg3 : metadata API version to write at the end of the manifest
write_package() {
  local output_path="$1"
  local body="$2"
  local version="$3"

  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<Package xmlns="http://soap.sforce.com/2006/04/metadata">'
    printf '%b' "$body"
    printf '    <version>%s</version>\n' "$version"
    printf '%s\n' '</Package>'
  } > "$output_path"
}

if [ ! -f "$SOURCE_PACKAGE_XML" ]; then
  echo "Source package XML not found: $SOURCE_PACKAGE_XML"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

PACKAGE_VERSION="$(extract_version)"
METADATA_BODY=""
OMNI_BODY=""
CURRENT_BLOCK=""
INSIDE_TYPES_BLOCK="false"

while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" == *"<types>"* ]]; then
    INSIDE_TYPES_BLOCK="true"
    CURRENT_BLOCK="${line}"$'\n'
    continue
  fi

  if [[ "$INSIDE_TYPES_BLOCK" == "true" ]]; then
    CURRENT_BLOCK="${CURRENT_BLOCK}${line}"$'\n'

    if [[ "$line" == *"</types>"* ]]; then
      BLOCK_TYPE_NAME="$(printf '%s' "$CURRENT_BLOCK" | sed -n 's:.*<name>\(.*\)</name>.*:\1:p' | tail -1)"

      if contains_omni_type "$BLOCK_TYPE_NAME"; then
        OMNI_BODY="${OMNI_BODY}${CURRENT_BLOCK}"
      else
        METADATA_BODY="${METADATA_BODY}${CURRENT_BLOCK}"
      fi

      CURRENT_BLOCK=""
      INSIDE_TYPES_BLOCK="false"
    fi
  fi
done < "$SOURCE_PACKAGE_XML"

write_package "${OUTPUT_DIR}/SF_Metadata.xml" "$METADATA_BODY" "$PACKAGE_VERSION"
write_package "${OUTPUT_DIR}/SF_Omni.xml" "$OMNI_BODY" "$PACKAGE_VERSION"

echo "Generated split manifests:"
echo " - ${OUTPUT_DIR}/SF_Metadata.xml"
echo " - ${OUTPUT_DIR}/SF_Omni.xml"