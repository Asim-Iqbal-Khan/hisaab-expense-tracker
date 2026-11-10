import { Router } from "express";
import { pool } from "../db";
import { requireAuth } from "../auth";
import { getUserIdByCognitoSub } from "../users";

export const notificationsRouter = Router();

notificationsRouter.get("/api/me/notification-prefs", requireAuth, async (req, res) => {
  try {
    const userId = await getUserIdByCognitoSub(req.cognitoSub!);
    if (!userId) {
      res.status(404).json({ error: "No profile found for this account yet" });
      return;
    }

    const prefsResult = await pool.query(
      `SELECT notify_events, notify_reminder FROM user_notification_prefs WHERE user_id = $1`,
      [userId],
    );
    const prefs = prefsResult.rows[0];
    if (!prefs) {
      res.status(404).json({ error: "No notification preferences found for this account yet" });
      return;
    }

    res.status(200).json(prefs);
  } catch (err) {
    console.error(
      "GET /api/me/notification-prefs failed:",
      err instanceof Error ? err.message : err,
    );
    res.status(500).json({ error: "Failed to load notification preferences" });
  }
});

notificationsRouter.put("/api/me/notification-prefs", requireAuth, async (req, res) => {
  try {
    const userId = await getUserIdByCognitoSub(req.cognitoSub!);
    if (!userId) {
      res.status(404).json({ error: "No profile found for this account yet" });
      return;
    }

    const { notify_events, notify_reminder } = req.body ?? {};
    if (notify_events !== undefined && typeof notify_events !== "boolean") {
      res.status(400).json({ error: "notify_events must be a boolean" });
      return;
    }
    if (notify_reminder !== undefined && typeof notify_reminder !== "boolean") {
      res.status(400).json({ error: "notify_reminder must be a boolean" });
      return;
    }

    const result = await pool.query(
      `UPDATE user_notification_prefs
       SET notify_events = COALESCE($1, notify_events),
           notify_reminder = COALESCE($2, notify_reminder),
           updated_at = now()
       WHERE user_id = $3
       RETURNING notify_events, notify_reminder`,
      [notify_events ?? null, notify_reminder ?? null, userId],
    );
    if (!result.rows[0]) {
      res.status(404).json({ error: "No notification preferences found for this account yet" });
      return;
    }

    res.status(200).json(result.rows[0]);
  } catch (err) {
    console.error(
      "PUT /api/me/notification-prefs failed:",
      err instanceof Error ? err.message : err,
    );
    res.status(500).json({ error: "Failed to update notification preferences" });
  }
});
