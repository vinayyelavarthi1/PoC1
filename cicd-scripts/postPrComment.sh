#!/bin/bash

COMMENT="$1"
COMMENTTYPE="$2"
URLFILTER='?cursor=&filter=special%3Adelta%3Dnew&sort=severity%7Cdesc'

echo "POST PIPELINE PR COMMENT:"
echo "$COMMENT"
if [[ "$COMMENTTYPE" == "validate" ]]; then
  echo "Posting validation comment."
else
  echo "Posting blackduck scan comment."
  if [ -z "$COMMENT" ]; then
    COMMENT="Execution of pipeline didn't find a PR comment."
  else 
    COMMENT=`printf "New Issues can be found here once the scan finishes %s%s" $COMMENT $URLFILTER`
  fi
fi
curl -X POST \
  "https://api.bitbucket.org/2.0/repositories/$BITBUCKET_WORKSPACE/$BITBUCKET_REPO_SLUG/pullrequests/$BITBUCKET_PR_ID/comments" \
  -u "$BITBUCKET_SVC_USERNAME:$BITBUCKET_OAUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"content\": {\"raw\": \"$COMMENT\"}}"
