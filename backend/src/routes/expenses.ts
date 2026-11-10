import { Router } from "express";
import { pool, withTransaction } from "../db";
import { requireAuth } from "../auth";
import { getUserIdByCognitoSub } from "../users";
import { isUuid, isValidNonFutureDate } from "../validation";
import { assertActiveMember } from "../groupAccess";
import { publishEventNotification } from "../sqs";
import { invalidateBalanceCaches } from "../cache";

export const expensesRouter = Router();

const EXPENSE_SELECT = `
  SELECT e.id, e.group_id, e.description, e.amount_paisa, e.paid_by, e.created_by,
         to_char(e.expense_date, 'YYYY-MM-DD') AS expense_date, e.created_at,
         u.username AS paid_by_username, u.display_name AS paid_by_display_name
  FROM expenses e
  JOIN users u ON u.id = e.paid_by
`;

interface ValidatedBody {
  description: string;
  amountPaisa: number;
  expenseDate: string;
  paidBy: string;
  splitUserIds: string[];
}

function validateBody(body: unknown): ValidatedBody | { error: string } {
  const b = (body ?? {}) as Record<string, unknown>;

  const description = typeof b.description === "string" ? b.description.trim() : "";
  if (description.length < 1 || description.length > 140) {
    return { error: "Description must be 1-140 characters" };
  }

  const amountPaisa = b.amountPaisa;
  if (typeof amountPaisa !== "number" || !Number.isInteger(amountPaisa) || amountPaisa <= 0) {
    return { error: "amountPaisa must be a positive integer" };
  }

  if (!isValidNonFutureDate(b.expenseDate)) {
    return { error: "expenseDate must be a valid, non-future date (YYYY-MM-DD)" };
  }
  const expenseDate = b.expenseDate as string;

  const paidBy = b.paidBy;
  if (typeof paidBy !== "string" || !isUuid(paidBy)) {
    return { error: "paidBy is required" };
  }

  const splitUserIds = b.splitUserIds;
  if (
    !Array.isArray(splitUserIds) ||
    splitUserIds.length === 0 ||
    !splitUserIds.every((v) => typeof v === "string" && isUuid(v))
  ) {
    return { error: "splitUserIds must be a non-empty array of user ids" };
  }
  if (new Set(splitUserIds).size !== splitUserIds.length) {
    return { error: "Duplicate members in split" };
  }

  return { description, amountPaisa, expenseDate, paidBy, splitUserIds };
}

// PRD: "Remainder paisa from uneven division are distributed one each to the
// first N members by ascending user_id — deterministic." Postgres's uuid
// comparison is raw-byte-based, not collation-dependent, so sorting canonical
// lowercase UUID strings here matches it with no locale mismatch risk.
function computeSplits(amountPaisa: number, userIds: string[]): Map<string, number> {
  const sorted = [...userIds].map((id) => id.toLowerCase()).sort();
  const n = sorted.length;
  const base = Math.floor(amountPaisa / n);
  const remainder = amountPaisa % n;
  const shares = new Map<string, number>();
  sorted.forEach((id, i) => {
    shares.set(id, base + (i < remainder ? 1 : 0));
  });
  return shares;
}

async function fetchSplits(expenseIds: string[]): Promise<Map<string, unknown[]>> {
  const byExpense = new Map<string, unknown[]>();
  if (expenseIds.length === 0) {
    return byExpense;
  }
  const result = await pool.query(
    `SELECT es.expense_id, es.user_id, es.share_paisa, u.username, u.display_name
     FROM expense_splits es
     JOIN users u ON u.id = es.user_id
     WHERE es.expense_id = ANY($1::uuid[])`,
    [expenseIds],
  );
  for (const row of result.rows) {
    const list = byExpense.get(row.expense_id) ?? [];
    list.push(row);
    byExpense.set(row.expense_id, list);
  }
  return byExpense;
}

expensesRouter.post("/api/groups/:id/expenses", requireAuth, async (req, res) => {
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
    const { description, amountPaisa, expenseDate, paidBy, splitUserIds } = validated;

    const activeMembersResult = await pool.query(
      `SELECT user_id FROM group_members WHERE group_id = $1 AND left_at IS NULL`,
      [groupId],
    );
    const activeMemberIds = new Set(activeMembersResult.rows.map((r) => r.user_id as string));
    if (!activeMemberIds.has(paidBy)) {
      res.status(400).json({ error: "paidBy must be an active member of this group" });
      return;
    }
    if (!splitUserIds.every((id) => activeMemberIds.has(id))) {
      res.status(400).json({ error: "All split members must be active members of this group" });
      return;
    }

    const shares = computeSplits(amountPaisa, splitUserIds);

    const expense = await withTransaction(async (client) => {
      const expenseResult = await client.query(
        `INSERT INTO expenses (group_id, description, amount_paisa, paid_by, expense_date, created_by)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING id, group_id, description, amount_paisa, paid_by, created_by,
                   to_char(expense_date, 'YYYY-MM-DD') AS expense_date, created_at`,
        [groupId, description, amountPaisa, paidBy, expenseDate, userId],
      );
      const newExpense = expenseResult.rows[0];

      for (const [splitUserId, share] of shares) {
        await client.query(
          `INSERT INTO expense_splits (expense_id, group_id, user_id, share_paisa)
           VALUES ($1, $2, $3, $4)`,
          [newExpense.id, groupId, splitUserId, share],
        );
      }

      const payload = JSON.stringify({
        description,
        amount_paisa: String(amountPaisa),
        paid_by: paidBy,
      });
      await client.query(
        `INSERT INTO activity_events (group_id, actor_id, event_type, expense_id, payload)
         VALUES ($1, $2, 'expense_added', $3, $4)`,
        [groupId, userId, newExpense.id, payload],
      );

      return newExpense;
    });

    // Every split member + the payer had their own net balance change —
    // unlike the notification targets below, this must include the actor
    // themselves if they're also a split member or the payer.
    await invalidateBalanceCaches(groupId, new Set([...splitUserIds, paidBy]));

    const involvedIds = new Set([...splitUserIds, paidBy]);
    involvedIds.delete(userId);
    const amountRupees = (amountPaisa / 100).toFixed(2);
    await Promise.all(
      [...involvedIds].map((involvedId) =>
        publishEventNotification(
          involvedId,
          "New expense on Hisaab",
          `An expense involving you was added: "${description}" (Rs ${amountRupees}).`,
        ),
      ),
    );

    res.status(201).json(expense);
  } catch (err) {
    console.error("POST /api/groups/:id/expenses failed:", err instanceof Error ? err.message : err);
    res.status(500).json({ error: "Failed to create expense" });
  }
});

expensesRouter.get("/api/groups/:id/expenses", requireAuth, async (req, res) => {
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

    const expensesResult = await pool.query(
      `${EXPENSE_SELECT}
       WHERE e.group_id = $1 AND e.deleted_at IS NULL
       ORDER BY e.expense_date DESC, e.created_at DESC`,
      [groupId],
    );

    const splitsByExpense = await fetchSplits(expensesResult.rows.map((r) => r.id));
    const expenses = expensesResult.rows.map((e) => ({
      ...e,
      splits: splitsByExpense.get(e.id) ?? [],
    }));

    res.status(200).json(expenses);
  } catch (err) {
    console.error("GET /api/groups/:id/expenses failed:", err instanceof Error ? err.message : err);
    res.status(500).json({ error: "Failed to load expenses" });
  }
});

expensesRouter.get("/api/groups/:id/expenses/:expenseId", requireAuth, async (req, res) => {
  try {
    const { id: groupId, expenseId } = req.params;
    if (!isUuid(groupId) || !isUuid(expenseId)) {
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

    const expenseResult = await pool.query(
      `${EXPENSE_SELECT} WHERE e.id = $1 AND e.group_id = $2 AND e.deleted_at IS NULL`,
      [expenseId, groupId],
    );
    const expense = expenseResult.rows[0];
    if (!expense) {
      res.status(404).json({ error: "Expense not found" });
      return;
    }

    const splitsByExpense = await fetchSplits([expenseId]);
    res.status(200).json({ ...expense, splits: splitsByExpense.get(expenseId) ?? [] });
  } catch (err) {
    console.error(
      "GET /api/groups/:id/expenses/:expenseId failed:",
      err instanceof Error ? err.message : err,
    );
    res.status(500).json({ error: "Failed to load expense" });
  }
});

expensesRouter.put("/api/groups/:id/expenses/:expenseId", requireAuth, async (req, res) => {
  try {
    const { id: groupId, expenseId } = req.params;
    if (!isUuid(groupId) || !isUuid(expenseId)) {
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
      `SELECT description, amount_paisa, paid_by, created_by,
              to_char(expense_date, 'YYYY-MM-DD') AS expense_date
       FROM expenses WHERE id = $1 AND group_id = $2 AND deleted_at IS NULL`,
      [expenseId, groupId],
    );
    const existing = existingResult.rows[0];
    if (!existing) {
      res.status(404).json({ error: "Expense not found" });
      return;
    }

    // Only whoever added the expense or the person who paid may edit it —
    // reversed from an earlier PRD-literal "any member" reading once the
    // real-world implication (anyone can silently rewrite anyone else's
    // entry) came up.
    if (existing.created_by !== userId && existing.paid_by !== userId) {
      res.status(403).json({ error: "Only the creator or payer may edit this expense" });
      return;
    }

    const existingSplitsResult = await pool.query(
      `SELECT user_id FROM expense_splits WHERE expense_id = $1`,
      [expenseId],
    );
    // A member who has since left the group may still be the payer or in the
    // split of an expense recorded while they were active — editing an
    // unrelated field (e.g. fixing a typo) must not silently drop them just
    // because they no longer show up as an active member.
    const priorParticipantIds = new Set<string>([
      existing.paid_by,
      ...existingSplitsResult.rows.map((r) => r.user_id as string),
    ]);

    const validated = validateBody(req.body);
    if ("error" in validated) {
      res.status(400).json({ error: validated.error });
      return;
    }
    const { description, amountPaisa, expenseDate, paidBy, splitUserIds } = validated;

    const activeMembersResult = await pool.query(
      `SELECT user_id FROM group_members WHERE group_id = $1 AND left_at IS NULL`,
      [groupId],
    );
    const allowedIds = new Set<string>([
      ...activeMembersResult.rows.map((r) => r.user_id as string),
      ...priorParticipantIds,
    ]);
    if (!allowedIds.has(paidBy)) {
      res.status(400).json({ error: "paidBy must be an active or previously-involved member" });
      return;
    }
    if (!splitUserIds.every((id) => allowedIds.has(id))) {
      res.status(400).json({ error: "All split members must be active or previously-involved members" });
      return;
    }

    const shares = computeSplits(amountPaisa, splitUserIds);

    await withTransaction(async (client) => {
      await client.query(
        `UPDATE expenses SET description = $1, amount_paisa = $2, paid_by = $3, expense_date = $4
         WHERE id = $5`,
        [description, amountPaisa, paidBy, expenseDate, expenseId],
      );

      await client.query(`DELETE FROM expense_splits WHERE expense_id = $1`, [expenseId]);
      for (const [splitUserId, share] of shares) {
        await client.query(
          `INSERT INTO expense_splits (expense_id, group_id, user_id, share_paisa)
           VALUES ($1, $2, $3, $4)`,
          [expenseId, groupId, splitUserId, share],
        );
      }

      const payload = JSON.stringify({
        before: {
          description: existing.description,
          amount_paisa: String(existing.amount_paisa),
          paid_by: existing.paid_by,
        },
        after: {
          description,
          amount_paisa: String(amountPaisa),
          paid_by: paidBy,
        },
      });
      await client.query(
        `INSERT INTO activity_events (group_id, actor_id, event_type, expense_id, payload)
         VALUES ($1, $2, 'expense_edited', $3, $4)`,
        [groupId, userId, expenseId, payload],
      );
    });

    // Union of who was involved before *and* after the edit — someone
    // dropped from the split needs their stale cached balance cleared too,
    // not just whoever's involved in the new version.
    const affectedUserIds = new Set([...priorParticipantIds, ...splitUserIds, paidBy]);
    await invalidateBalanceCaches(groupId, affectedUserIds);

    res.status(204).send();
  } catch (err) {
    console.error(
      "PUT /api/groups/:id/expenses/:expenseId failed:",
      err instanceof Error ? err.message : err,
    );
    res.status(500).json({ error: "Failed to update expense" });
  }
});

expensesRouter.delete("/api/groups/:id/expenses/:expenseId", requireAuth, async (req, res) => {
  try {
    const { id: groupId, expenseId } = req.params;
    if (!isUuid(groupId) || !isUuid(expenseId)) {
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
      `SELECT description, amount_paisa, paid_by, created_by,
              to_char(expense_date, 'YYYY-MM-DD') AS expense_date
       FROM expenses WHERE id = $1 AND group_id = $2 AND deleted_at IS NULL`,
      [expenseId, groupId],
    );
    const existing = existingResult.rows[0];
    if (!existing) {
      res.status(404).json({ error: "Expense not found" });
      return;
    }

    if (existing.created_by !== userId && existing.paid_by !== userId) {
      res.status(403).json({ error: "Only the creator or payer may delete this expense" });
      return;
    }

    const splitsResult = await pool.query(`SELECT user_id FROM expense_splits WHERE expense_id = $1`, [
      expenseId,
    ]);
    const affectedUserIds = new Set<string>([
      existing.paid_by,
      ...splitsResult.rows.map((r) => r.user_id as string),
    ]);

    const payload = JSON.stringify({
      description: existing.description,
      amount_paisa: String(existing.amount_paisa),
      paid_by: existing.paid_by,
      expense_date: existing.expense_date,
    });

    await withTransaction(async (client) => {
      await client.query(`UPDATE expenses SET deleted_at = now() WHERE id = $1`, [expenseId]);
      await client.query(
        `INSERT INTO activity_events (group_id, actor_id, event_type, expense_id, payload)
         VALUES ($1, $2, 'expense_deleted', $3, $4)`,
        [groupId, userId, expenseId, payload],
      );
    });

    await invalidateBalanceCaches(groupId, affectedUserIds);

    res.status(204).send();
  } catch (err) {
    console.error(
      "DELETE /api/groups/:id/expenses/:expenseId failed:",
      err instanceof Error ? err.message : err,
    );
    res.status(500).json({ error: "Failed to delete expense" });
  }
});
