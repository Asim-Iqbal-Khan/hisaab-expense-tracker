import { Router } from "express";
import { pool, withTransaction } from "../db";
import { requireAuth } from "../auth";
import { getUserIdByCognitoSub } from "../users";
import { isUuid } from "../validation";
import { assertActiveMember } from "../groupAccess";
import { publishEventNotification } from "../sqs";
import { invalidateBalanceCaches } from "../cache";

export const settlementsRouter = Router();

interface ValidatedSettlementBody {
  counterpartyUserId: string;
  direction: "i_paid" | "i_received";
  amountPaisa: number;
  note: string | null;
}

function validateBody(body: unknown): ValidatedSettlementBody | { error: string } {
  const b = (body ?? {}) as Record<string, unknown>;

  const counterpartyUserId = b.counterpartyUserId;
  if (typeof counterpartyUserId !== "string" || !isUuid(counterpartyUserId)) {
    return { error: "counterpartyUserId is required" };
  }

  const direction = b.direction;
  if (direction !== "i_paid" && direction !== "i_received") {
    return { error: "direction must be 'i_paid' or 'i_received'" };
  }

  const amountPaisa = b.amountPaisa;
  if (typeof amountPaisa !== "number" || !Number.isInteger(amountPaisa) || amountPaisa <= 0) {
    return { error: "amountPaisa must be a positive integer" };
  }

  let note: string | null = null;
  if (b.note !== undefined && b.note !== null) {
    if (typeof b.note !== "string" || b.note.trim().length > 140) {
      return { error: "note must be a string of at most 140 characters" };
    }
    note = b.note.trim() || null;
  }

  return { counterpartyUserId, direction, amountPaisa, note };
}

settlementsRouter.post("/api/groups/:id/settlements", requireAuth, async (req, res) => {
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

    const validated = validateBody(req.body);
    if ("error" in validated) {
      res.status(400).json({ error: validated.error });
      return;
    }
    const { counterpartyUserId, direction, amountPaisa, note } = validated;

    if (counterpartyUserId === userId) {
      res.status(400).json({ error: "Cannot record a settlement with yourself" });
      return;
    }

    // The counterparty only needs to have ever been a member (no left_at
    // filter) — settling up with someone who has since left the group is
    // the exact scenario F5's departed-counterparty balance handling exists
    // for. The caller themselves must still be active (assertActiveMember
    // above already enforced that).
    const counterpartyResult = await pool.query(
      `SELECT 1 FROM group_members WHERE group_id = $1 AND user_id = $2`,
      [groupId, counterpartyUserId],
    );
    if (counterpartyResult.rowCount === 0) {
      res.status(400).json({ error: "counterpartyUserId has never been a member of this group" });
      return;
    }

    const fromUserId = direction === "i_paid" ? userId : counterpartyUserId;
    const toUserId = direction === "i_paid" ? counterpartyUserId : userId;

    const settlement = await withTransaction(async (client) => {
      const settlementResult = await client.query(
        `INSERT INTO settlements (group_id, from_user_id, to_user_id, amount_paisa, note, created_by)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING id, group_id, from_user_id, to_user_id, amount_paisa, note, created_at`,
        [groupId, fromUserId, toUserId, amountPaisa, note, userId],
      );
      const newSettlement = settlementResult.rows[0];

      const payload = JSON.stringify({
        from_user_id: fromUserId,
        to_user_id: toUserId,
        amount_paisa: String(amountPaisa),
        note,
      });
      await client.query(
        `INSERT INTO activity_events (group_id, actor_id, event_type, settlement_id, payload)
         VALUES ($1, $2, 'settlement_recorded', $3, $4)`,
        [groupId, userId, newSettlement.id, payload],
      );

      return newSettlement;
    });

    await invalidateBalanceCaches(groupId, [userId, counterpartyUserId]);

    const amountRupees = (amountPaisa / 100).toFixed(2);
    await publishEventNotification(
      counterpartyUserId,
      "Settlement recorded on Hisaab",
      `Someone recorded a settlement with you: Rs ${amountRupees}.`,
    );

    res.status(201).json(settlement);
  } catch (err) {
    console.error(
      "POST /api/groups/:id/settlements failed:",
      err instanceof Error ? err.message : err,
    );
    res.status(500).json({ error: "Failed to record settlement" });
  }
});

settlementsRouter.get("/api/groups/:id/settlements", requireAuth, async (req, res) => {
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

    const result = await pool.query(
      `SELECT s.id, s.from_user_id, s.to_user_id, s.amount_paisa, s.note, s.created_at,
              fu.username AS from_username, fu.display_name AS from_display_name,
              tu.username AS to_username, tu.display_name AS to_display_name
       FROM settlements s
       JOIN users fu ON fu.id = s.from_user_id
       JOIN users tu ON tu.id = s.to_user_id
       WHERE s.group_id = $1 AND s.deleted_at IS NULL
       ORDER BY s.created_at DESC`,
      [groupId],
    );

    res.status(200).json(result.rows);
  } catch (err) {
    console.error("GET /api/groups/:id/settlements failed:", err instanceof Error ? err.message : err);
    res.status(500).json({ error: "Failed to load settlements" });
  }
});

settlementsRouter.delete("/api/groups/:id/settlements/:settlementId", requireAuth, async (req, res) => {
  try {
    const { id: groupId, settlementId } = req.params;
    if (!isUuid(groupId) || !isUuid(settlementId)) {
      res.status(400).json({ error: "Invalid id" });
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

    const existingResult = await pool.query(
      `SELECT from_user_id, to_user_id, amount_paisa, note
       FROM settlements WHERE id = $1 AND group_id = $2 AND deleted_at IS NULL`,
      [settlementId, groupId],
    );
    const existing = existingResult.rows[0];
    if (!existing) {
      res.status(404).json({ error: "Settlement not found" });
      return;
    }

    // Narrower than expenses' "any member" rule, deliberately — PRD says
    // settlements are created by "either party," and deletion follows the
    // same two-parties-only model, confirmed explicitly rather than
    // defaulting to the broader expenses convention.
    if (existing.from_user_id !== userId && existing.to_user_id !== userId) {
      res.status(403).json({ error: "Only the parties involved may delete this settlement" });
      return;
    }

    const payload = JSON.stringify({
      from_user_id: existing.from_user_id,
      to_user_id: existing.to_user_id,
      amount_paisa: String(existing.amount_paisa),
      note: existing.note,
    });

    await withTransaction(async (client) => {
      await client.query(`UPDATE settlements SET deleted_at = now() WHERE id = $1`, [settlementId]);
      await client.query(
        `INSERT INTO activity_events (group_id, actor_id, event_type, settlement_id, payload)
         VALUES ($1, $2, 'settlement_deleted', $3, $4)`,
        [groupId, userId, settlementId, payload],
      );
    });

    await invalidateBalanceCaches(groupId, [existing.from_user_id, existing.to_user_id]);

    res.status(204).send();
  } catch (err) {
    console.error(
      "DELETE /api/groups/:id/settlements/:settlementId failed:",
      err instanceof Error ? err.message : err,
    );
    res.status(500).json({ error: "Failed to delete settlement" });
  }
});
