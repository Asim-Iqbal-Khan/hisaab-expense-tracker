import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";
import { pool } from "./db";
import { config } from "./config";

const sqsClient = new SQSClient({ region: config.awsRegion });

// Replaces the old SNS topic + per-user filter-policy subscription model.
// fn-email-sender (SQS-triggered) does the actual send via SES — this just
// enqueues {to, subject, body}, resolving the recipient's email itself
// since there's no more subscription to carry it implicitly.
//
// Preference enforcement happens here, once, before every event-driven
// enqueue (PRD: "preferences are honoured before the message is published,
// not filtered afterwards") — callers never need to check notify_events
// themselves.
export async function publishEventNotification(
  userId: string,
  subject: string,
  message: string,
): Promise<void> {
  const result = await pool.query(
    `SELECT u.email, unp.notify_events
     FROM users u JOIN user_notification_prefs unp ON unp.user_id = u.id
     WHERE u.id = $1`,
    [userId],
  );
  const row = result.rows[0];
  if (!row || row.notify_events !== true) {
    return;
  }

  await sqsClient.send(
    new SendMessageCommand({
      QueueUrl: config.sqsQueueUrl,
      MessageBody: JSON.stringify({ to: row.email, subject, body: message }),
    }),
  );
}
