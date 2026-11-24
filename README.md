# Amazon Bedrock model invocation logging: permissions, and Amazon Connect AI agents

A practical guide to two common questions:

1. What IAM permissions does Amazon Bedrock model invocation logging need?
2. If I use Amazon Connect AI agents, will their model calls show up in Bedrock model invocation logs?

Everything here is based on the public AWS documentation plus tests run in a personal test account in November 2026. The test scripts are included so you can reproduce the results. Service behaviour can change, so re-test before relying on it.

## TL;DR

- **The role that calls the models needs nothing extra.** Invocation logging is configured once per account and Region and applies to every caller. A role with only `bedrock:InvokeModel` was still logged.
- **The identity that turns logging on needs `bedrock:PutModelInvocationLoggingConfiguration` and `iam:PassRole` on the logging role** (CloudWatch Logs destination). Without `iam:PassRole` the call fails with `AccessDeniedException`.
- **The CloudWatch Logs logging role** needs `logs:CreateLogStream` and `logs:PutLogEvents`. Its trust policy must allow `bedrock.amazonaws.com`, and the `aws:SourceArn` condition must match the Region you enable logging in. Bedrock validates the role when you save the configuration, so a mistake is rejected straight away.
- **Amazon Connect AI agent model calls did NOT appear in Bedrock model invocation logs.** Use the Connect AI agent logs (assistant `EVENT_LOGS`) and the `ListSpans` API instead. They capture the prompt, completion and model ID for each model invocation.

## 1. Permissions for model invocation logging

Reference: [Monitor model invocation using CloudWatch Logs and Amazon S3](https://docs.aws.amazon.com/bedrock/latest/userguide/model-invocation-logging.html).

> "You can use model invocation logging to collect invocation logs, model input data, and model output data for all invocations in your AWS account used in Amazon Bedrock in a Region."

There are three separate identities involved. People often assume it is their existing "Bedrock role", but that is the one that needs nothing.

### a) The role calling the model: no changes

Logging is an account and Region setting, not a per-role setting. In testing, a role whose only permission was `bedrock:InvokeModel` made a `Converse` call, and the call was logged with that role's ARN in the `identity` field.

### b) The identity that enables logging

Needs, at minimum:

- `bedrock:PutModelInvocationLoggingConfiguration`
- `iam:PassRole` on the CloudWatch Logs logging role

See [`policies/enable-logging-caller-policy.json`](policies/enable-logging-caller-policy.json). It also includes the Get and Delete actions for managing the setting.

What happens without `iam:PassRole` (observed):

```
An error occurred (AccessDeniedException) when calling the PutModelInvocationLoggingConfiguration operation:
User: arn:aws:sts::<ACCOUNT_ID>:assumed-role/invlog-test-caller-putonly/invlogtest is not authorized to perform:
iam:PassRole on resource: arn:aws:iam::<ACCOUNT_ID>:role/invlog-test-logrole-ok because no identity-based policy allows the iam:PassRole action
```

The S3-only destination was not tested here. Per the docs, Bedrock can attach the bucket policy for you if the caller has `s3:GetBucketPolicy` and `s3:PutBucketPolicy`.

### c) The logging destination

**CloudWatch Logs**: an IAM role that Bedrock assumes.

- Trust policy: [`policies/cloudwatch-logging-role-trust.json`](policies/cloudwatch-logging-role-trust.json)
- Permissions: [`policies/cloudwatch-logging-role-policy.json`](policies/cloudwatch-logging-role-policy.json)

When you save the configuration, Bedrock checks the role by writing a test event. With a correct role, the log group immediately gets:

```
Permissions are correctly set for Amazon Bedrock logs.
```

Two misconfigurations tested, both rejected when saving (observed):

| Misconfiguration | Error |
|---|---|
| Trust policy `aws:SourceArn` scoped to a different Region | `ValidationException: Failed to validate permissions for log group: <LG>, with role: <ROLE>. Verify the IAM role permissions are correct.` |
| Role missing `logs:PutLogEvents` | Same `ValidationException` |

Watch out for the Region trap: a logging role created for `us-east-1` (with `arn:aws:bedrock:us-east-1:...` in its trust condition) can't be reused as-is in another Region.

**Amazon S3**: a bucket policy that allows `bedrock.amazonaws.com` to call `s3:PutObject`. Add `kms:GenerateDataKey` on the key if the bucket uses SSE-KMS. Bucket ACLs must be disabled. See [`policies/s3-bucket-policy.json`](policies/s3-bucket-policy.json) and the doc above. This destination was not tested here.

## 2. Amazon Connect AI agents and invocation logging

Test: Bedrock model invocation logging was enabled in the Region, and a direct `Converse` control call confirmed it was working. A Connect assistant was then created, and the system `SelfServiceOrchestratorChat` AI agent was sent several messages. The agent replied, and `ListSpans` showed `inference` spans with `providerName: aws.bedrock` and a Claude Haiku model, so Bedrock models were being called.

Observed:

| Where | Connect AI agent model calls found |
|---|---|
| Bedrock model invocation log group | 0 (only the control call) |
| CloudTrail `bedrock.amazonaws.com` events | 0 (only the control call) |
| Connect AI agent logs (assistant `EVENT_LOGS` to CloudWatch) | Yes: `TRANSCRIPT_LARGE_LANGUAGE_MODEL_INVOCATION` entries with `prompt`, `completion`, `model_id`, plus orchestration and trace events |

Inferred (not documented): Amazon Connect calls the model on the service side rather than from your account, so your account's invocation logging and CloudTrail don't see those calls.

So if your goal is visibility into what your Connect AI agents send to and get back from the model, use Connect's own logging:

- [Monitor AI agents using CloudWatch](https://docs.aws.amazon.com/connect/latest/adminguide/monitor-ai-agents.html): create a log delivery for the assistant (`PutDeliverySource` with `logType` `EVENT_LOGS`, then `PutDeliveryDestination` and `CreateDelivery`) to CloudWatch Logs, S3 or Firehose. Needs `wisdom:AllowVendedLogDeliveryForResource`.
- [Logging and tracing for AI agents](https://docs.aws.amazon.com/connect/latest/adminguide/viewing-logs-for-connect-ai-agents-self-service.html): describes the log event types, and recommends the `ListSpans` API for tracing orchestrator AI agent sessions.

Bedrock model invocation logging is still worth enabling if you also call Bedrock directly, for example from Lambda functions used as Connect flow integrations or from other applications.

Limitation of this test: the AI agent was driven directly through the Amazon Q in Connect APIs (`CreateSession`, `SendMessage`), not through a Connect contact flow. The same result is expected through a flow, but that was not tested.

## Reproduce it

Prereqs: AWS CLI, `jq`, [`uv`](https://docs.astral.sh/uv/), and admin credentials in a test account. The scripts set and delete the account/Region invocation logging configuration, so use a Region where it isn't already configured.

```bash
# Permission tests (CloudWatch Logs destination)
ACCOUNT_ID=111122223333 REGION=us-west-2 ./scripts/test-permissions.sh

# Connect AI agent vs invocation logs (enable invocation logging in the Region first)
REGION=eu-central-1 ACCOUNT_ID=111122223333 INVLOG_GROUP=/my/bedrock-invocation-logs ./scripts/test-connect-ai-agent.py
```

Both scripts clean up the resources they create. Model calls incur normal Bedrock charges, but the amount is tiny.

## Files

```
README.md
policies/enable-logging-caller-policy.json   identity that turns logging on
policies/cloudwatch-logging-role-trust.json  logging role trust policy
policies/cloudwatch-logging-role-policy.json logging role permissions
policies/s3-bucket-policy.json               S3 destination bucket policy
scripts/test-permissions.sh                  permission tests 1-5
scripts/test-connect-ai-agent.py             Connect AI agent logging comparison
```

Not official AWS guidance. Placeholders like `<ACCOUNT_ID>` need replacing with your own values.
