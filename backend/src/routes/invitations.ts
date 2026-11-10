import { Router } from "express";
import { pool, withTransaction } from "../db";
import { requireAuth } from "../auth";
import { getUserIdByCognitoSub } from "../users";
import { isUuid } from "../validation";
import { publishEventNotification } from "../sqs";

export const invitationsRouter = Router();

const GROUP_MEMBER_CAP = 20;

function isUniqueViolation(err: unknown): boolean {
  return typeof err === "object" && err !== null && (err as { code?: string }).code === "23505";
}

invitationsRouter.post("/api/groups/:id/invitations", requireAuth, async (req, res) => {
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

    const inviteeUserId = req.body?.inviteeUserId;
    if (typeof inviteeUserId !== "string" || !isUuid(inviteeUserId)) {
      res.status(400).json({ error: "inviteeUserId is required" });
      return;
    }
    if (inviteeUserId === userId) {
      res.status(400).json({ error: "Cannot invite yourself" });
      return;
    }

    const inviteeResult = await pool.query(`SELECT 1 FROM users WHERE id = $1`, [inviteeUserId]);
    if (inviteeResult.rowCount === 0) {
      res.status(404).json({ error: "User not found" });
      return;
    }

    const alreadyMemberResult = await pool.query(
      `SELECT 1 FROM group_members WHERE group_id = $1 AND user_id = $2 AND left_at IS NULL`,
      [groupId, inviteeUserId],
    );
    if ((alreadyMemberResult.rowCount ?? 0) > 0) {
      res.status(409).json({ error: "User is already a member of this group" });
      return;
    }

    const invitationResult = await pool.query(
      `INSERT INTO group_invitations (group_id, invitee_id, invited_by)
       VALUES ($1, $2, $3)
       RETURNING id, group_id, invitee_id, invited_by, status, created_at`,
      [groupId, inviteeUserId, userId],
    );

    const groupResult = await pool.query(`SELECT name FROM groups WHERE id = $1`, [groupId]);
    await publishEventNotification(
      inviteeUserId,
      "You've been invited to a group on Hisaab",
      `You've been invited to join "${groupResult.rows[0]?.name ?? "a group"}" on Hisaab.`,
    );

    res.status(201).json(invitationResult.rows[0]);
  } catch (err) {
    if (isUniqueViolation(err)) {
      res.status(409).json({ error: "User already has a pending invitation to this group" });
      return;
    }
    console.error(
      "POST /api/groups/:id/invitations failed:",
      err instanceof Error ? err.message : err,
    );
    res.status(500).json({ error: "Failed to send invitation" });
  }
});

invitationsRouter.get("/api/invitations", requireAuth, async (req, res) => {
  try {
    const userId = await getUserIdByCognitoSub(req.cognitoSub!);
    if (!userId) {
      res.status(404).json({ error: "No profile found for this account yet" });
      return;
    }

    const result = await pool.query(
      `SELECT gi.id, gi.group_id, g.name AS group_name, gi.invited_by,
              u.username AS inviter_username, u.display_name AS inviter_display_name,
              gi.created_at
       FROM group_invitations gi
       JOIN groups g ON g.id = gi.group_id
       JOIN users u ON u.id = gi.invited_by
       WHERE gi.invitee_id = $1 AND gi.status = 'pending'
       ORDER BY gi.created_at DESC`,
      [userId],
    );

    res.status(200).json(result.rows);
  } catch (err) {
    console.error("GET /api/invitations failed:", err instanceof Error ? err.message : err);
    res.status(500).json({ error: "Failed to load invitations" });
  }
});

invitationsRouter.post("/api/invitations/:id/accept", requireAuth, async (req, res) => {
  try {
    const invitationId = req.params.id;
    if (!isUuid(invitationId)) {
      res.status(400).json({ error: "Invalid invitation id" });
      return;
    }

    const userId = await getUserIdByCognitoSub(req.cognitoSub!);
    if (!userId) {
      res.status(404).json({ error: "No profile found for this account yet" });
      return;
    }

    const invitationResult = await pool.query(
      `SELECT id, group_id, invitee_id, status FROM group_invitations WHERE id = $1`,
      [invitationId],
    );
    const invitation = invitationResult.rows[0];
    if (!invitation) {
      res.status(404).json({ error: "Invitation not found" });
      return;
    }
    if (invitation.invitee_id !== userId) {
      res.status(403).json({ error: "Not your invitation" });
      return;
    }
    if (invitation.status !== "pending") {
      res.status(409).json({ error: "Invitation is no longer pending" });
      return;
    }

    const memberCountResult = await pool.query(
      `SELECT count(*) AS count FROM group_members WHERE group_id = $1 AND left_at IS NULL`,
      [invitation.group_id],
    );
    if (Number(memberCountResult.rows[0].count) >= GROUP_MEMBER_CAP) {
      res.status(409).json({ error: "Group is at its member limit" });
      return;
    }

    await withTransaction(async (client) => {
      await client.query(
        `UPDATE group_invitations SET status = 'accepted', responded_at = now() WHERE id = $1`,
        [invitationId],
      );

      const rejoinResult = await client.query(
        `UPDATE group_members SET left_at = NULL WHERE group_id = $1 AND user_id = $2`,
        [invitation.group_id, userId],
      );
      if (rejoinResult.rowCount === 0) {
        await client.query(`INSERT INTO group_members (group_id, user_id) VALUES ($1, $2)`, [
          invitation.group_id,
          userId,
        ]);
      }

      await client.query(
        `INSERT INTO activity_events (group_id, actor_id, event_type, subject_user_id)
         VALUES ($1, $2, 'member_joined', $2)`,
        [invitation.group_id, userId],
      );
    });

    res.status(204).send();
  } catch (err) {
    console.error(
      "POST /api/invitations/:id/accept failed:",
      err instanceof Error ? err.message : err,
    );
    res.status(500).json({ error: "Failed to accept invitation" });
  }
});

invitationsRouter.post("/api/invitations/:id/reject", requireAuth, async (req, res) => {
  try {
    const invitationId = req.params.id;
    if (!isUuid(invitationId)) {
      res.status(400).json({ error: "Invalid invitation id" });
      return;
    }

    const userId = await getUserIdByCognitoSub(req.cognitoSub!);
    if (!userId) {
      res.status(404).json({ error: "No profile found for this account yet" });
      return;
    }

    const invitationResult = await pool.query(
      `SELECT id, invitee_id, status FROM group_invitations WHERE id = $1`,
      [invitationId],
    );
    const invitation = invitationResult.rows[0];
    if (!invitation) {
      res.status(404).json({ error: "Invitation not found" });
      return;
    }
    if (invitation.invitee_id !== userId) {
      res.status(403).json({ error: "Not your invitation" });
      return;
    }
    if (invitation.status !== "pending") {
      res.status(409).json({ error: "Invitation is no longer pending" });
      return;
    }

    // No activity event on rejection, deliberately — the group should not
    // see who declined (PRD F2).
    await pool.query(
      `UPDATE group_invitations SET status = 'rejected', responded_at = now() WHERE id = $1`,
      [invitationId],
    );

    res.status(204).send();
  } catch (err) {
    console.error(
      "POST /api/invitations/:id/reject failed:",
      err instanceof Error ? err.message : err,
    );
    res.status(500).json({ error: "Failed to reject invitation" });
  }
});

invitationsRouter.delete("/api/invitations/:id", requireAuth, async (req, res) => {
  try {
    const invitationId = req.params.id;
    if (!isUuid(invitationId)) {
      res.status(400).json({ error: "Invalid invitation id" });
      return;
    }

    const userId = await getUserIdByCognitoSub(req.cognitoSub!);
    if (!userId) {
      res.status(404).json({ error: "No profile found for this account yet" });
      return;
    }

    const invitationResult = await pool.query(
      `SELECT id, invited_by, status FROM group_invitations WHERE id = $1`,
      [invitationId],
    );
    const invitation = invitationResult.rows[0];
    if (!invitation) {
      res.status(404).json({ error: "Invitation not found" });
      return;
    }
    if (invitation.invited_by !== userId) {
      res.status(403).json({ error: "Only the original inviter can cancel this invitation" });
      return;
    }
    if (invitation.status !== "pending") {
      res.status(409).json({ error: "Invitation is no longer pending" });
      return;
    }

    await pool.query(
      `UPDATE group_invitations SET status = 'cancelled', responded_at = now() WHERE id = $1`,
      [invitationId],
    );

    res.status(204).send();
  } catch (err) {
    console.error("DELETE /api/invitations/:id failed:", err instanceof Error ? err.message : err);
    res.status(500).json({ error: "Failed to cancel invitation" });
  }
});
