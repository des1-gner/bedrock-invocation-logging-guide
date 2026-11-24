#!/bin/bash
# Reproduces the permission tests for Amazon Bedrock model invocation logging
# (CloudWatch Logs destination). Run in a TEST account and Region where model
# invocation logging is NOT already configured: this script sets and then deletes
# the account/Region logging configuration.
#
# Usage: ACCOUNT_ID=111122223333 REGION=us-west-2 ./test-permissions.sh
set -uo pipefail
: "${ACCOUNT_ID:?set ACCOUNT_ID}"; : "${REGION:?set REGION}"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
MODEL_ID="${MODEL_ID:-us.amazon.nova-lite-v1:0}"
LG=/test/invlog-perm-test
P=invlog-test
WORK=$(mktemp -d)

existing=$(aws bedrock get-model-invocation-logging-configuration --output text)
if [ -n "$existing" ]; then echo "Logging already configured in $REGION, refusing to overwrite." >&2; exit 1; fi

trust_bedrock() { cat <<J
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"bedrock.amazonaws.com"},"Action":"sts:AssumeRole","Condition":{"StringEquals":{"aws:SourceAccount":"$ACCOUNT_ID"},"ArnLike":{"aws:SourceArn":"arn:aws:bedrock:$1:$ACCOUNT_ID:*"}}}]}
J
}
trust_account='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::'"$ACCOUNT_ID"':root"},"Action":"sts:AssumeRole"}]}'
stream="arn:aws:logs:$REGION:$ACCOUNT_ID:log-group:$LG:log-stream:aws/bedrock/modelinvocations"
logpol() { echo "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":$1,\"Resource\":\"$stream\"}]}"; }
mkrole() { aws iam create-role --role-name "$1" --assume-role-policy-document "$2" >/dev/null && aws iam put-role-policy --role-name "$1" --policy-name p --policy-document "$3"; }
cfg() { echo "{\"cloudWatchConfig\":{\"logGroupName\":\"$LG\",\"roleArn\":\"arn:aws:iam::$ACCOUNT_ID:role/$1\"},\"textDataDeliveryEnabled\":true}"; }
assume() { aws sts assume-role --role-arn "arn:aws:iam::$ACCOUNT_ID:role/$1" --role-session-name invlogtest --query Credentials --output json > "$WORK/$1.json"; }
as() { local f="$WORK/$1.json"; shift; env -u AWS_PROFILE -u AWS_SHARED_CREDENTIALS_FILE AWS_ACCESS_KEY_ID="$(jq -r .AccessKeyId "$f")" AWS_SECRET_ACCESS_KEY="$(jq -r .SecretAccessKey "$f")" AWS_SESSION_TOKEN="$(jq -r .SessionToken "$f")" "$@"; }

cleanup() {
  aws bedrock delete-model-invocation-logging-configuration 2>/dev/null
  aws logs delete-log-group --log-group-name "$LG" 2>/dev/null
  for r in logrole-ok logrole-wrongregion logrole-noput caller-putonly caller-passrole modelcaller; do
    aws iam delete-role-policy --role-name "$P-$r" --policy-name p 2>/dev/null; aws iam delete-role --role-name "$P-$r" 2>/dev/null
  done
  rm -rf "$WORK"; echo "cleaned up" >&2
}
trap cleanup EXIT

aws logs create-log-group --log-group-name "$LG"
OTHER_REGION=$([ "$REGION" = us-east-1 ] && echo us-west-2 || echo us-east-1)
mkrole $P-logrole-ok "$(trust_bedrock "$REGION")" "$(logpol '["logs:CreateLogStream","logs:PutLogEvents"]')"
mkrole $P-logrole-wrongregion "$(trust_bedrock "$OTHER_REGION")" "$(logpol '["logs:CreateLogStream","logs:PutLogEvents"]')"
mkrole $P-logrole-noput "$(trust_bedrock "$REGION")" "$(logpol '["logs:CreateLogStream"]')"
mkrole $P-caller-putonly "$trust_account" '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["bedrock:PutModelInvocationLoggingConfiguration"],"Resource":"*"}]}'
mkrole $P-caller-passrole "$trust_account" "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"bedrock:PutModelInvocationLoggingConfiguration\"],\"Resource\":\"*\"},{\"Effect\":\"Allow\",\"Action\":\"iam:PassRole\",\"Resource\":\"arn:aws:iam::$ACCOUNT_ID:role/$P-logrole-ok\"}]}"
mkrole $P-modelcaller "$trust_account" '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["bedrock:InvokeModel"],"Resource":"*"}]}'
echo "waiting for IAM propagation..." >&2; sleep 15
for r in caller-putonly caller-passrole modelcaller; do assume $P-$r; done

echo "### Test 1: enable logging with ONLY bedrock:PutModelInvocationLoggingConfiguration"
as $P-caller-putonly aws bedrock put-model-invocation-logging-configuration --logging-config "$(cfg $P-logrole-ok)" 2>&1 | tail -1

echo "### Test 2: enable logging with Put + iam:PassRole on the logging role"
as $P-caller-passrole aws bedrock put-model-invocation-logging-configuration --logging-config "$(cfg $P-logrole-ok)" 2>&1 | tail -1 && echo "OK"

echo "### Test 3: logging role whose trust policy is scoped to $OTHER_REGION"
aws bedrock put-model-invocation-logging-configuration --logging-config "$(cfg $P-logrole-wrongregion)" 2>&1 | tail -1

echo "### Test 4: logging role missing logs:PutLogEvents"
aws bedrock put-model-invocation-logging-configuration --logging-config "$(cfg $P-logrole-noput)" 2>&1 | tail -1

echo "### Test 5: model caller with ONLY bedrock:InvokeModel is still logged"
aws bedrock put-model-invocation-logging-configuration --logging-config "$(cfg $P-logrole-ok)" >/dev/null
as $P-modelcaller aws bedrock-runtime converse --model-id "$MODEL_ID" --messages '[{"role":"user","content":[{"text":"INVLOG-PERM-TEST say hi"}]}]' --query 'output.message.content[0].text' --output text
echo "waiting for log delivery..." >&2; sleep 45
aws logs filter-log-events --log-group-name "$LG" --query 'events[].message' --output text | grep -oE '"identity":\{"arn":"[^"]+"\}|INVLOG-PERM-TEST' | sort | uniq -c
