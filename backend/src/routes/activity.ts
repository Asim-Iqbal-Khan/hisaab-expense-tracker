import { Router } from "express";
import { pool } from "../db";
import { requireAuth } from "../auth";
import { getUserIdByCognitoSub } from "../users";
import { isUuid } from "../validation";
import { assertActiveMember } from "../groupAccess";

export const activityRouter = Router();

const DEFAULT_LIMIT = 20;
const MAX_LIMIT = 50;

// Event payloads (written by groups.ts/invitations.ts/expenses.ts/settlements.ts)
// embed other user ids under these keys, either at the top level or nested
// under before/after (expense_edited) — collected here so every referenced
// user can be resolved to a display name in one batch query.
const PAYLOAD_USER_KEYS = ["paid_by", "from_user_id", "to_user_id"];

function collectPayloadUserIds(payload: unknown, into: Set<string>) {
  if (!payload || typeof payload !== "object") return;
  const obj = payload as Record<string, unknown>;
  for (const key of PAYLOAD_USER_KEYS) {
    if (typeof obj[key] === "string") into.add(obj[key] as string);
  }
  for (const key of ["before", "after"]) {
    const nested = obj[key];
    if (nested && typeof nested === "object") {
      collectPayloadUserIds(nested, into);
    }
  }
}

activityRouter.get("/api/groups/:id/activity", requireAuth, async (req, res) => {
  try {
    const groupId = req.params.id;
    if (!isUuid(groupId)) {
      res.status(400).json({ error: "Invalid group id" });
      return;
    }

    const userId = await getUserIdByCognitoSub(req.cognitoSub!);
    if (!userId) {
      res.status(404).json({ error: "No profile found for this account yet" });
      return;
    }

    const membership = await assertActiveMember(groupId, userId);
    if (!membership.ok) {
      res.status(membership.status).json({ error: membership.error });
      return;
    }

    let limit = DEFAULT_LIMIT;
    if (req.query.limit !== undefined) {
      const parsed = Number(req.query.limit);
      if (!Number.isInteger(parsed) || parsed < 1 || parsed > MAX_LIMIT) {
        res.status(400).json({ error: `limit must be an integer between 1 and ${MAX_LIMIT}` });
        return;
      }
      limit = parsed;
    }

    const params: unknown[] = [groupId];
    let whereClause = "group_id = $1";
    if (req.query.before !== undefined) {
      const parsedBefore = Number(req.query.before);
      if (!Number.isInteger(parsedBefore)) {
        res.status(400).json({ error: "before must be an integer event id" });
        return;
      }
      params.push(parsedBefore);
      whereClause += ` AND id < $${params.length}`;
    }
    params.push(limit + 1);

    const result = await pool.query(
      `SELECT id, actor_id, event_type, payload, created_at
       FROM activity_events
       WHERE ${whereClause}
       ORDER BY id DESC
       LIMIT $${params.length}`,
      params,
    );

    const hasMore = result.rows.length > limit;
    const rows = hasMore ? result.rows.slice(0, limit) : result.rows;

    const referencedIds = new Set<string>();
    for (const row of rows) {
      referencedIds.add(row.actor_id);
      collectPayloadUserIds(row.payload, referencedIds);
    }

    const userInfoResult =
      referencedIds.size > 0
        ? await pool.query(`SELECT id, username, display_name FROM users WHERE id = ANY($1::uuid[])`, [
            [...referencedIds],
          ])
        : { rows: [] as { id: string; username: string; display_name: string }[] };

    const users: Record<string, { username: string; display_name: string }> = {};
    for (const row of userInfoResult.rows) {
      users[row.id] = { username: row.username, display_name: row.display_name };
    }

    const events = rows.map((row) => ({
      id: String(row.id),
      actor_id: row.actor_id,
      event_type: row.event_type,
      payload: row.payload,
      created_at: row.created_at,
    }));

    res.status(200).json({ events, users, has_more: hasMore });
  } catch (err) {
    console.error("GET /api/groups/:id/activity failed:", err instanceof Error ? err.message : err);
    res.status(500).json({ error: "Failed to load activity" });
  }
});
