import { Router } from "express";
import { pool, withTransaction } from "../db";
import { requireAuth } from "../auth";
import { getUserIdByCognitoSub } from "../users";
import { isUuid } from "../validation";

export const groupsRouter = Router();

// Hand-rolled sliding-window limiter for user search (PRD suggests 30/min).
// Per-process, in-memory — doesn't share state across multiple app instances
// behind the ALB, an accepted gap given there's no Redis/ElastiCache in this
// infra yet.
const SEARCH_WINDOW_MS = 60_000;
const SEARCH_LIMIT = 30;
const searchHits = new Map<string, number[]>();

function isRateLimited(key: string): boolean {
  const now = Date.now();
  const hits = (searchHits.get(key) ?? []).filter((t) => now - t < SEARCH_WINDOW_MS);
  hits.push(now);
  searchHits.set(key, hits);
  return hits.length > SEARCH_LIMIT;
}

groupsRouter.post("/api/groups", requireAuth, async (req, res) => {
  try {
    const userId = await getUserIdByCognitoSub(req.cognitoSub!);
    if (!userId) {
      res.status(404).json({ error: "No profile found for this account yet" });
      return;
    }

    const name = typeof req.body?.name === "string" ? req.body.name.trim() : "";
    if (name.length < 1 || name.length > 50) {
      res.status(400).json({ error: "Group name must be 1-50 characters" });
      return;
    }

    const group = await withTransaction(async (client) => {
      const groupResult = await client.query(
        `INSERT INTO groups (name, created_by) VALUES ($1, $2)
         RETURNING id, name, created_by, created_at`,
        [name, userId],
      );
      const newGroup = groupResult.rows[0];

      await client.query(`INSERT INTO group_members (group_id, user_id) VALUES ($1, $2)`, [
        newGroup.id,
        userId,
      ]);

      await client.query(
        `INSERT INTO activity_events (group_id, actor_id, event_type, subject_user_id)
         VALUES ($1, $2, 'member_joined', $2)`,
        [newGroup.id, userId],
      );

      return newGroup;
    });

    res.status(201).json(group);
  } catch (err) {
    console.error("POST /api/groups failed:", err instanceof Error ? err.message : err);
    res.status(500).json({ error: "Failed to create group" });
  }
});

groupsRouter.get("/api/groups", requireAuth, async (req, res) => {
  try {
    const userId = await getUserIdByCognitoSub(req.cognitoSub!);
    if (!userId) {
      res.status(404).json({ error: "No profile found for this account yet" });
      return;
    }

    const result = await pool.query(
      `SELECT g.id, g.name, g.created_by, g.created_at,
              COALESCE(nb.net_paisa, 0) AS net_paisa
       FROM group_members gm
       JOIN groups g ON g.id = gm.group_id
       LEFT JOIN v_net_balances nb ON nb.group_id = g.id AND nb.user_id = gm.user_id
       WHERE gm.user_id = $1 AND gm.left_at IS NULL AND g.deleted_at IS NULL
       ORDER BY g.created_at DESC`,
      [userId],
    );

    res.status(200).json(result.rows);
  } catch (err) {
    console.error("GET /api/groups failed:", err instanceof Error ? err.message : err);
    res.status(500).json({ error: "Failed to load groups" });
  }
});

groupsRouter.get("/api/groups/:id", requireAuth, async (req, res) => {
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

    const groupResult = await pool.query(
      `SELECT id, name, created_by, created_at FROM groups WHERE id = $1 AND deleted_at IS NULL`,
      [groupId],
    );
    const group = groupResult.rows[0];
    if (!group) {
      res.status(404).json({ error: "Group not found" });
      return;
    }

    const membershipResult = await pool.query(
      `SELECT 1 FROM group_members WHERE group_id = $1 AND user_id = $2 AND left_at IS NULL`,
      [groupId, userId],
    );
    if (membershipResult.rowCount === 0) {
      res.status(403).json({ error: "Not a member of this group" });
      return;
    }

    const membersResult = await pool.query(
      `SELECT u.id, u.username, u.display_name, u.avatar_s3_key, gm.joined_at
       FROM group_members gm
       JOIN users u ON u.id = gm.user_id
       WHERE gm.group_id = $1 AND gm.left_at IS NULL
       ORDER BY gm.joined_at ASC`,
      [groupId],
    );

    const invitationsResult = await pool.query(
      `SELECT gi.id, gi.invitee_id, u.username AS invitee_username,
              u.display_name AS invitee_display_name, gi.invited_by, gi.created_at
       FROM group_invitations gi
       JOIN users u ON u.id = gi.invitee_id
       WHERE gi.group_id = $1 AND gi.status = 'pending'
       ORDER BY gi.created_at DESC`,
      [groupId],
    );

    res.status(200).json({
      ...group,
      members: membersResult.rows,
      pending_invitations: invitationsResult.rows,
    });
  } catch (err) {
    console.error("GET /api/groups/:id failed:", err instanceof Error ? err.message : err);
    res.status(500).json({ error: "Failed to load group" });
  }
});

groupsRouter.post("/api/groups/:id/leave", requireAuth, async (req, res) => {
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

    const membershipResult = await pool.query(
      `SELECT 1 FROM group_members WHERE group_id = $1 AND user_id = $2 AND left_at IS NULL`,
      [groupId, userId],
    );
    if (membershipResult.rowCount === 0) {
      res.status(403).json({ error: "Not a member of this group" });
      return;
    }

    const balanceResult = await pool.query(
      `SELECT COALESCE(net_paisa, 0) AS net_paisa FROM v_net_balances
       WHERE group_id = $1 AND user_id = $2`,
      [groupId, userId],
    );
    const netPaisa = Number(balanceResult.rows[0]?.net_paisa ?? 0);
    if (netPaisa !== 0) {
      res.status(409).json({ error: "Cannot leave a group with a nonzero balance" });
      return;
    }

    await withTransaction(async (client) => {
      await client.query(
        `UPDATE group_members SET left_at = now() WHERE group_id = $1 AND user_id = $2`,
        [groupId, userId],
      );
      await client.query(
        `INSERT INTO activity_events (group_id, actor_id, event_type, subject_user_id)
         VALUES ($1, $2, 'member_left', $2)`,
        [groupId, userId],
      );
    });

    res.status(204).send();
  } catch (err) {
    console.error("POST /api/groups/:id/leave failed:", err instanceof Error ? err.message : err);
    res.status(500).json({ error: "Failed to leave group" });
  }
});

groupsRouter.delete("/api/groups/:id", requireAuth, async (req, res) => {
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

    const groupResult = await pool.query(`SELECT 1 FROM groups WHERE id = $1 AND deleted_at IS NULL`, [
      groupId,
    ]);
    if (groupResult.rowCount === 0) {
      res.status(404).json({ error: "Group not found" });
      return;
    }

    const membershipResult = await pool.query(
      `SELECT 1 FROM group_members WHERE group_id = $1 AND user_id = $2 AND left_at IS NULL`,
      [groupId, userId],
    );
    if (membershipResult.rowCount === 0) {
      res.status(403).json({ error: "Not a member of this group" });
      return;
    }

    const outstandingResult = await pool.query(
      `SELECT 1 FROM v_net_balances WHERE group_id = $1 AND net_paisa <> 0 LIMIT 1`,
      [groupId],
    );
    if ((outstandingResult.rowCount ?? 0) > 0) {
      res.status(409).json({ error: "Cannot delete a group with outstanding balances" });
      return;
    }

    await pool.query(`UPDATE groups SET deleted_at = now() WHERE id = $1`, [groupId]);
    res.status(204).send();
  } catch (err) {
    console.error("DELETE /api/groups/:id failed:", err instanceof Error ? err.message : err);
    res.status(500).json({ error: "Failed to delete group" });
  }
});

groupsRouter.get("/api/groups/:id/user-search", requireAuth, async (req, res) => {
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

    const membershipResult = await pool.query(
      `SELECT 1 FROM group_members WHERE group_id = $1 AND user_id = $2 AND left_at IS NULL`,
      [groupId, userId],
    );
    if (membershipResult.rowCount === 0) {
      res.status(403).json({ error: "Not a member of this group" });
      return;
    }

    if (isRateLimited(userId)) {
      res.status(429).json({ error: "Too many searches — try again in a minute" });
      return;
    }

    const q = typeof req.query.q === "string" ? req.query.q.trim() : "";
    if (q.length < 3) {
      res.status(400).json({ error: "Search query must be at least 3 characters" });
      return;
    }

    const result = await pool.query(
      `SELECT u.id, u.username, u.display_name, u.avatar_s3_key
       FROM users u
       WHERE u.username LIKE $2 || '%'
         AND u.anonymised_at IS NULL
         AND u.id <> $3
         AND NOT EXISTS (
           SELECT 1 FROM group_members gm
           WHERE gm.group_id = $1 AND gm.user_id = u.id AND gm.left_at IS NULL
         )
         AND NOT EXISTS (
           SELECT 1 FROM group_invitations gi
           WHERE gi.group_id = $1 AND gi.invitee_id = u.id AND gi.status = 'pending'
         )
       ORDER BY u.username ASC
       LIMIT 20`,
      [groupId, q, userId],
    );

    res.status(200).json(result.rows);
  } catch (err) {
    console.error(
      "GET /api/groups/:id/user-search failed:",
      err instanceof Error ? err.message : err,
    );
    res.status(500).json({ error: "Search failed" });
  }
});
