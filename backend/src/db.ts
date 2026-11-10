import { Pool, PoolClient } from "pg";
import { config } from "./config";

interface DbSecret {
  username: string;
  password: string;
}

const secret: DbSecret = JSON.parse(config.dbSecretJson);

export const pool = new Pool({
  host: config.dbHost,
  port: config.dbPort,
  database: config.dbName,
  user: secret.username,
  password: secret.password,
  // RDS rejects unencrypted connections outright (confirmed the hard way:
  // "no pg_hba.conf entry ... no encryption"). Not validating against
  // RDS's CA bundle here — the connection is encrypted either way, this
  // just skips verifying the server's identity, an accepted tradeoff for
  // traffic that never leaves the VPC. config.dbSsl exists so local dev
  // against a plain local Postgres (no SSL configured) can turn this off.
  ssl: config.dbSsl ? { rejectUnauthorized: false } : false,
});

export async function withTransaction<T>(fn: (client: PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}
