import { pool } from "./db";

export async function assertActiveMember(
  groupId: string,
  userId: string,
): Promise<{ ok: true } | { ok: false; status: number; error: string }> {
  const groupResult = await pool.query(`SELECT 1 FROM groups WHERE id = $1 AND deleted_at IS NULL`, [
    groupId,
  ]);
  if (groupResult.rowCount === 0) {
    return { ok: false, status: 404, error: "Group not found" };
  }

  const membershipResult = await pool.query(
    `SELECT 1 FROM group_members WHERE group_id = $1 AND user_id = $2 AND left_at IS NULL`,
    [groupId, userId],
  );
  if (membershipResult.rowCount === 0) {
    return { ok: false, status: 403, error: "Not a member of this group" };
  }

  return { ok: true };
}
