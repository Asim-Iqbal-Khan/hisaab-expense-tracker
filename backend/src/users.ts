import { pool } from "./db";

export async function getUserIdByCognitoSub(cognitoSub: string): Promise<string | null> {
  const result = await pool.query<{ id: string }>("SELECT id FROM users WHERE cognito_sub = $1", [
    cognitoSub,
  ]);
  return result.rows[0]?.id ?? null;
}
