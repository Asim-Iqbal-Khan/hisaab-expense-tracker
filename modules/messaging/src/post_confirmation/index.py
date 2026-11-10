import json
import os
import re
import secrets
import ssl

import boto3
import pg8000.dbapi

USERNAME_RE = re.compile(r"[^a-z0-9_]")

secrets_client = boto3.client("secretsmanager", region_name=os.environ["AWS_REGION_NAME"])
ses_client = boto3.client("ses", region_name=os.environ["AWS_REGION_NAME"])


def sanitize_username(raw: str, sub: str) -> str:
    candidate = USERNAME_RE.sub("", raw.lower())[:20]
    if len(candidate) < 3:
        return f"user_{sub[:8]}"
    return candidate


def get_connection():
    secret = json.loads(
        secrets_client.get_secret_value(SecretId=os.environ["DB_SECRET_ARN"])["SecretString"]
    )
    # RDS rejects unencrypted connections outright — same finding as the
    # Node backend's `ssl: { rejectUnauthorized: false }`. Not verifying
    # the server cert here for the same reason: traffic never leaves the
    # VPC either way.
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


def handler(event, context):
    """Creates the `users` row (and its `user_notification_prefs` row) for a
    newly confirmed Cognito user (spec 10.1). Notification delivery itself
    (SQS + SES) doesn't need any per-user setup — nothing to subscribe to.
    """
    attrs = event["request"]["userAttributes"]
    sub = attrs["sub"]
    email = attrs["email"]
    preferred_username = attrs.get("preferred_username", "")

    username = sanitize_username(preferred_username, sub)
    display_name = (preferred_username or email.split("@")[0]).strip()[:50] or username

    conn = get_connection()
    try:
        # Not a context manager — pg8000.dbapi.Cursor doesn't implement
        # __enter__/__exit__ (confirmed against the installed version),
        # unlike psycopg2's cursor. `with conn.cursor() as cur:` raises
        # TypeError before any query ever runs.
        cur = conn.cursor()
        user_id = insert_user(cur, sub, username, display_name, email)
        if user_id is not None:
            cur.execute(
                "INSERT INTO user_notification_prefs (user_id) VALUES (%s)",
                (user_id,),
            )
        conn.commit()
    finally:
        conn.close()

    # Best-effort, and deliberately after the commit above: the account's
    # SES sending is in sandbox mode, which only allows delivery to
    # individually-verified recipients (§10.1). This is how every new user
    # gets verified, without ever needing AWS's manual production-access
    # approval. A transient failure here must not undo the users row that
    # was already committed — that's exactly the orphaned-account failure
    # mode this trigger already hit once before (missing table, that time).
    #
    # verify_email_identity, not send_custom_verification_email — confirmed
    # the hard way that the custom-branded version itself requires
    # production access to use at all ("ProductionAccessNotGranted"),
    # which defeats the entire point for a sandboxed account. This sends
    # AWS's own generic verification email instead of a Hisaab-branded
    # one; revisit once production access is actually granted.
    if user_id is not None:
        try:
            ses_client.verify_email_identity(EmailAddress=email)
        except Exception as err:
            print(f"verify_email_identity failed for {email}: {err}")

    return event


def insert_user(cur, sub: str, username: str, display_name: str, email: str):
    cur.execute(
        """
        INSERT INTO users (cognito_sub, username, display_name, email)
        VALUES (%s, %s, %s, %s)
        ON CONFLICT (cognito_sub) DO NOTHING
        RETURNING id
        """,
        (sub, username, display_name, email),
    )
    row = cur.fetchone()
    if row is not None:
        return row[0]

    # cognito_sub already existed (retry of the same trigger) — nothing new to insert.
    cur.execute("SELECT id FROM users WHERE cognito_sub = %s", (sub,))
    existing = cur.fetchone()
    if existing is not None:
        return None

    # cognito_sub was new but username/email collided with a different user
    # (only possible via the sanitize_username fallback producing a clash) —
    # retry once with a random suffix.
    retry_username = f"{username[:14]}_{secrets.token_hex(2)}"
    cur.execute(
        """
        INSERT INTO users (cognito_sub, username, display_name, email)
        VALUES (%s, %s, %s, %s)
        RETURNING id
        """,
        (sub, retry_username, display_name, email),
    )
    return cur.fetchone()[0]
