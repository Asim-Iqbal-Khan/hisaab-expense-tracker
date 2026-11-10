import json
import os

import boto3

ses_client = boto3.client("ses", region_name=os.environ["AWS_REGION_NAME"])


def handler(event, context):
    """SQS-triggered. No DB access, no VPC — the producers (the API,
    fn-reminder-dispatcher) already resolved the recipient email and
    checked notify_events/notify_reminder before enqueueing; this Lambda's
    only job is to send each queued {to, subject, body} via SES.

    Returns batchItemFailures (partial-batch-response format) so a single
    bad message doesn't cause the whole batch — including already-sent
    emails — to be redelivered.
    """
    failures = []

    for record in event["Records"]:
        message_id = record["messageId"]
        try:
            body = json.loads(record["body"])
            ses_client.send_email(
                Source=os.environ["SES_FROM_ADDRESS"],
                Destination={"ToAddresses": [body["to"]]},
                Message={
                    "Subject": {"Data": body["subject"]},
                    "Body": {"Text": {"Data": body["body"]}},
                },
            )
        except Exception as err:
            print(f"Failed to send message {message_id}: {err}")
            failures.append({"itemIdentifier": message_id})

    return {"batchItemFailures": failures}
