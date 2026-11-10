import json
import os
import ssl

import boto3
import pg8000.dbapi

secrets_client = boto3.client("secretsmanager", region_name=os.environ["AWS_REGION_NAME"])
sqs_client = boto3.client("sqs", region_name=os.environ["AWS_REGION_NAME"])


def get_connection():
    secret = json.loads(
        secrets_client.get_secret_value(SecretId=os.environ["DB_SECRET_ARN"])["SecretString"]
    )
    # Same finding as post_confirmation/index.py and the Node backend: RDS
    # rejects unencrypted connections outright.
    ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE

    return pg8000.dbapi.connect(
        host=os.environ["DB_HOST"],
        port=int(os.environ["DB_PORT"]),
        database=os.environ["DB_NAME"],
        user=secret["username"],
        password=secret["password"],
        ssl_context=ssl_context,
    )


# Same pairwise-based "total owed" definition GET /api/balances/summary uses
# (backend/src/routes/balances.ts, on top of v_pairwise_ledger) — a per-group
# net position can be zero while a user genuinely owes one person and is
# separately owed by another, so summing per-group nets would understate or
# hide real debt. This is a literal copy, not a shared library (different
# language) — kept in sync by this comment cross-reference, the same
# "one authoritative definition, referenced not re-derived" spirit as the
# view itself.
REMINDER_QUERY = """
    WITH my_pairs AS (
        SELECT unp.user_id,
               u.email,
               CASE WHEN vpl.debtor = unp.user_id THEN -vpl.amount_paisa ELSE vpl.amount_paisa END AS signed_amount,
               vpl.group_id,
               CASE WHEN vpl.debtor = unp.user_id THEN vpl.creditor ELSE vpl.debtor END AS counterparty
        FROM user_notification_prefs unp
        JOIN users u ON u.id = unp.user_id
        JOIN v_pairwise_ledger vpl ON vpl.debtor = unp.user_id OR vpl.creditor = unp.user_id
        WHERE unp.notify_reminder = true
          AND (unp.last_reminded_at IS NULL OR unp.last_reminded_at < now() - interval '7 days')
    ),
    netted AS (
        SELECT user_id, email, group_id, counterparty, SUM(signed_amount) AS net_amount
        FROM my_pairs
        GROUP BY user_id, email, group_id, counterparty
    )
    SELECT user_id, email,
           SUM(CASE WHEN net_amount < 0 THEN -net_amount ELSE 0 END) AS owed_by_paisa
    FROM netted
    GROUP BY user_id, email
    HAVING SUM(CASE WHEN net_amount < 0 THEN -net_amount ELSE 0 END) > 0
"""


def handler(event, context):
    """Runs weekly (EventBridge Scheduler). Reminds every user who owes money
    somewhere, hasn't been reminded in the last 7 days, and has the weekly
    reminder preference on — one aggregated message per user summarising
    their total owed across all groups, never one message per group.
    """
    conn = get_connection()
    sent = 0
    try:
        cur = conn.cursor()
        cur.execute(REMINDER_QUERY)
        rows = cur.fetchall()

        for user_id, email, owed_by_paisa in rows:
            rupees = owed_by_paisa / 100
            sqs_client.send_message(
                QueueUrl=os.environ["SQS_QUEUE_URL"],
                MessageBody=json.dumps(
                    {
                        "to": email,
                        "subject": "Weekly balance reminder — Hisaab",
                        "body": f"You currently owe Rs {rupees:.2f} across your Hisaab groups.",
                    }
                ),
            )
            cur.execute(
                "UPDATE user_notification_prefs SET last_reminded_at = now() WHERE user_id = %s",
                (user_id,),
            )
            sent += 1

        conn.commit()
    finally:
        conn.close()

    return {"statusCode": 200, "remindersSent": sent}
