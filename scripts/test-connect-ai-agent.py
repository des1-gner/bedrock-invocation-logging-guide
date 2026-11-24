#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["boto3>=1.42"]
# ///
"""Checks whether Amazon Connect AI agent model calls appear in Bedrock model invocation logs.

Run in a TEST account/Region where model invocation logging is already enabled
(for example with test-permissions.sh's role, or the console), and pass the
invocation log group name. Creates a temporary assistant, enables its AI agent
event logs to a second log group, sends a few messages to the system
SelfServiceOrchestratorChat agent, then compares both log groups. Cleans up the
assistant and the AI agent log delivery afterwards.

Usage: REGION=eu-central-1 ACCOUNT_ID=111122223333 INVLOG_GROUP=/my/bedrock-invocation-logs ./test-connect-ai-agent.py
"""
import json, os, time
import boto3

REGION = os.environ["REGION"]; ACCOUNT_ID = os.environ["ACCOUNT_ID"]; INVLOG_GROUP = os.environ["INVLOG_GROUP"]
MARKER = f"CONNECT-AI-AGENT-TEST-{int(time.time())}"
AI_LOG_GROUP = "/test/connect-ai-agent-logs"
q = boto3.client("qconnect", region_name=REGION)
logs = boto3.client("logs", region_name=REGION)

def count(group, needle, start_ms):
    events = logs.filter_log_events(logGroupName=group, startTime=start_ms).get("events", [])
    return sum(needle in e["message"] for e in events)

aid = q.create_assistant(name="invlog-test-assistant", type="AGENT")["assistant"]["assistantId"]
src = dst = delivery = None
try:
    try: logs.create_log_group(logGroupName=AI_LOG_GROUP)
    except logs.exceptions.ResourceAlreadyExistsException: pass
    src = logs.put_delivery_source(name="invlog-test-src", resourceArn=f"arn:aws:wisdom:{REGION}:{ACCOUNT_ID}:assistant/{aid}", logType="EVENT_LOGS")["deliverySource"]["name"]
    dst = logs.put_delivery_destination(name="invlog-test-dst", outputFormat="json",
        deliveryDestinationConfiguration={"destinationResourceArn": f"arn:aws:logs:{REGION}:{ACCOUNT_ID}:log-group:{AI_LOG_GROUP}"})["deliveryDestination"]
    delivery = logs.create_delivery(deliverySourceName=src, deliveryDestinationArn=dst["arn"])["delivery"]["id"]

    agents = {a["name"]: a for a in q.list_ai_agents(assistantId=aid, origin="SYSTEM")["aiAgentSummaries"]}
    agent_id = agents["SelfServiceOrchestratorChat"]["aiAgentId"]
    start_ms = int(time.time() * 1000)
    sid = q.create_session(assistantId=aid, name=f"invlog-test-{int(time.time())}")["session"]["sessionId"]
    for text in (f"{MARKER} hello, what can you help me with?", f"{MARKER} I need help resetting my password"):
        r = q.send_message(assistantId=aid, sessionId=sid, type="TEXT", message={"value": {"text": {"value": text}}}, aiAgentId=agent_id)
        time.sleep(8)
        n = q.get_next_message(assistantId=aid, sessionId=sid, nextMessageToken=r["nextMessageToken"])
        print("agent replied:", n.get("response", {}).get("value", {}).get("text", {}).get("value", "").strip()[:120])
    spans = q.list_spans(assistantId=aid, sessionId=sid).get("spans", [])
    inference = [s["attributes"] for s in spans if s.get("attributes", {}).get("operationName") == "inference"]
    print(f"ListSpans inference spans: {len(inference)}", json.dumps([{k: a.get(k) for k in ('providerName', 'requestModel')} for a in inference]))
    print("waiting 90s for log delivery..."); time.sleep(90)
    print(f"Bedrock invocation log entries containing marker: {count(INVLOG_GROUP, MARKER, start_ms)}")
    print(f"Connect AI agent log entries containing marker:   {count(AI_LOG_GROUP, MARKER, start_ms)}")
finally:
    if delivery: logs.delete_delivery(id=delivery)
    if src: logs.delete_delivery_source(name=src)
    if dst: logs.delete_delivery_destination(name=dst["name"])
    q.delete_assistant(assistantId=aid)
    try: logs.delete_log_group(logGroupName=AI_LOG_GROUP)
    except Exception: pass
    print("cleaned up")
