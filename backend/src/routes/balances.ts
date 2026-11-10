import { Router } from "express";
import { pool } from "../db";
import { requireAuth } from "../auth";
import { getUserIdByCognitoSub } from "../users";
import { isUuid } from "../validation";
import { assertActiveMember } from "../groupAccess";
import {
  BALANCE_CACHE_TTL_SECONDS,
  getCached,
  groupBalanceCacheKey,
  setCached,
  userBalanceSummaryCacheKey,
} from "../cache";

export const balancesRouter = Router();

// Netted pairwise amounts for a group, on top of v_pairwise_ledger — the one
// authoritative place "how to filter for balance correctness" lives (see
// docs/hisaab-schema.sql). LEAST/GREATEST on uuid compare real byte values,
// not text, same guarantee computeSplits() in expenses.ts already relies on.
// HAVING ... <> 0 satisfies "zero balances are hidden from the pairwise view."
const PAIRWISE_QUERY = `
  SELECT LEAST(debtor, creditor) AS user_a_id,
         GREATEST(debtor, creditor) AS user_b_id,
         SUM(CASE WHEN debtor < creditor THEN amount_paisa ELSE -amount_paisa END) AS amount_paisa
  FROM v_pairwise_ledger
  WHERE group_id = $1
  GROUP BY LEAST(debtor, creditor), GREATEST(debtor, creditor)
  HAVING SUM(CASE WHEN debtor < creditor THEN amount_paisa ELSE -amount_paisa END) <> 0
`;

balancesRouter.get("/api/groups/:id/balances", requireAuth, async (req, res) => {
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

    // Cache check after the auth/membership check, never before — access
    // control must run on every request regardless of cache state.
    const cacheKey = groupBalanceCacheKey(groupId, userId);
    const cached = await getCached<{ net_paisa: string; pairwise: unknown[] }>(cacheKey);
    if (cached) {
      res.status(200).json(cached);
      return;
    }

    const netResult = await pool.query(
      `SELECT COALESCE(net_paisa, 0) AS net_paisa FROM v_net_balances WHERE group_id = $1 AND user_id = $2`,
      [groupId, userId],
    );
    const netPaisa = String(netResult.rows[0]?.net_paisa ?? 0);

    const pairwiseResult = await pool.query(PAIRWISE_QUERY, [groupId]);

    // A departed member can still have a real, nonzero pairwise balance (the
    // group's own leave-check only verifies aggregate net was zero) — fetch
    // display info for whoever actually appears in the pairwise rows, not
    // just active members, so their debt isn't silently dropped.
    const involvedIds = new Set<string>();
    for (const row of pairwiseResult.rows) {
      involvedIds.add(row.user_a_id);
      involvedIds.add(row.user_b_id);
    }

    const userInfoResult =
      involvedIds.size > 0
        ? await pool.query(
            `SELECT u.id, u.username, u.display_name, (gm.user_id IS NOT NULL) AS is_active
             FROM users u
             LEFT JOIN group_members gm
               ON gm.group_id = $1 AND gm.user_id = u.id AND gm.left_at IS NULL
             WHERE u.id = ANY($2::uuid[])`,
            [groupId, [...involvedIds]],
          )
        : { rows: [] as { id: string; username: string; display_name: string; is_active: boolean }[] };
    const userInfo = new Map(userInfoResult.rows.map((r) => [r.id, r]));

    const pairwise = pairwiseResult.rows.map((row) => {
      const a = userInfo.get(row.user_a_id);
      const b = userInfo.get(row.user_b_id);
      return {
        user_a_id: row.user_a_id,
        user_a_username: a?.username ?? null,
        user_a_display_name: a?.display_name ?? null,
        user_a_active: a?.is_active ?? false,
        user_b_id: row.user_b_id,
        user_b_username: b?.username ?? null,
        user_b_display_name: b?.display_name ?? null,
        user_b_active: b?.is_active ?? false,
        // Positive: user_a owes user_b. Negative: user_b owes user_a.
        amount_paisa: String(row.amount_paisa),
      };
    });

    const response = { net_paisa: netPaisa, pairwise };
    await setCached(cacheKey, response, BALANCE_CACHE_TTL_SECONDS);
    res.status(200).json(response);
  } catch (err) {
    console.error("GET /api/groups/:id/balances failed:", err instanceof Error ? err.message : err);
    res.status(500).json({ error: "Failed to load balances" });
  }
});

balancesRouter.get("/api/groups/:id/balances/detail", requireAuth, async (req, res) => {
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

    const { userA, userB } = req.query;
    if (
      typeof userA !== "string" ||
      typeof userB !== "string" ||
      !isUuid(userA) ||
      !isUuid(userB) ||
      userA === userB
    ) {
      res.status(400).json({ error: "userA and userB must be distinct valid user ids" });
      return;
    }

    // Same predicate v_pairwise_ledger's expense branch encodes (deleted_at IS
    // NULL, split user <> payer) — written directly against the base tables
    // here (not the view) since the view drops description/date needed for
    // display. Keep this in lockstep with the view's definition if it changes.
    const expensesResult = await pool.query(
      `SELECT e.id, e.description, e.amount_paisa, e.paid_by,
              to_char(e.expense_date, 'YYYY-MM-DD') AS expense_date, es.share_paisa
       FROM expenses e
       JOIN expense_splits es ON es.expense_id = e.id
       WHERE e.group_id = $1 AND e.deleted_at IS NULL AND es.user_id <> e.paid_by
         AND ((e.paid_by = $2 AND es.user_id = $3) OR (e.paid_by = $3 AND es.user_id = $2))
       ORDER BY e.expense_date DESC, e.created_at DESC`,
      [groupId, userA, userB],
    );

    const settlementsResult = await pool.query(
      `SELECT id, from_user_id, to_user_id, amount_paisa, note, created_at
       FROM settlements
       WHERE group_id = $1 AND deleted_at IS NULL
         AND ((from_user_id = $2 AND to_user_id = $3) OR (from_user_id = $3 AND to_user_id = $2))
       ORDER BY created_at DESC`,
      [groupId, userA, userB],
    );

    res.status(200).json({ expenses: expensesResult.rows, settlements: settlementsResult.rows });
  } catch (err) {
    console.error(
      "GET /api/groups/:id/balances/detail failed:",
      err instanceof Error ? err.message : err,
    );
    res.status(500).json({ error: "Failed to load balance detail" });
  }
});

balancesRouter.get("/api/balances/summary", requireAuth, async (req, res) => {
  try {
    const userId = await getUserIdByCognitoSub(req.cognitoSub!);
    if (!userId) {
      res.status(404).json({ error: "No profile found for this account yet" });
      return;
    }

    const cacheKey = userBalanceSummaryCacheKey(userId);
    const cached = await getCached<{ owed_to_user_paisa: string; owed_by_user_paisa: string }>(
      cacheKey,
    );
    if (cached) {
      res.status(200).json(cached);
      return;
    }

    // Sums pairwise magnitudes per (group, counterparty) — never netting
    // across different groups or different counterparties against each
    // other. A per-group net total can be zero while the user genuinely owes
    // one person and is separately owed by another; that must not cancel out
    // here. No group_members/active-membership join: debts persist regardless
    // of current membership status (see v_pairwise_ledger's own comment).
    const result = await pool.query(
      `WITH my_pairs AS (
         SELECT group_id,
                CASE WHEN debtor = $1 THEN creditor ELSE debtor END AS counterparty,
                CASE WHEN debtor = $1 THEN -amount_paisa ELSE amount_paisa END AS signed_amount
         FROM v_pairwise_ledger
         WHERE debtor = $1 OR creditor = $1
       ),
       netted AS (
         SELECT group_id, counterparty, SUM(signed_amount) AS net_amount
         FROM my_pairs
         GROUP BY group_id, counterparty
       )
       SELECT
         COALESCE(SUM(CASE WHEN net_amount > 0 THEN net_amount ELSE 0 END), 0) AS owed_to_user_paisa,
         COALESCE(SUM(CASE WHEN net_amount < 0 THEN -net_amount ELSE 0 END), 0) AS owed_by_user_paisa
       FROM netted`,
      [userId],
    );

    const row = result.rows[0];
    const response = {
      owed_to_user_paisa: String(row.owed_to_user_paisa),
      owed_by_user_paisa: String(row.owed_by_user_paisa),
    };
    await setCached(cacheKey, response, BALANCE_CACHE_TTL_SECONDS);
    res.status(200).json(response);
  } catch (err) {
    console.error("GET /api/balances/summary failed:", err instanceof Error ? err.message : err);
    res.status(500).json({ error: "Failed to load balance summary" });
  }
});
