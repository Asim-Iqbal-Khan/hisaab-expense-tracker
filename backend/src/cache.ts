import Redis from "ioredis";
import { config } from "./config";

// Balance/expense query cache — cache-aside with synchronous invalidation on
// write (see routes/balances.ts for reads, routes/expenses.ts and
// routes/settlements.ts for invalidation). Balances are read-your-own-write
// sensitive — the same reason they stayed off the read replica — so a plain
// TTL alone isn't enough; every write that can change a balance must
// invalidate the relevant keys itself. TTL below is a backstop for a missed
// invalidation path, not the primary mechanism.
//
// config.redisHost is deliberately optional (unlike every other config
// value): no Redis configured just means every function below is a no-op,
// so local dev never needs a real instance running, and the app degrades to
// "always hits the database" rather than breaking if the cache is ever
// unavailable in production too.
const redis: Redis | null = config.redisHost
  ? new Redis({
      host: config.redisHost,
      port: config.redisPort,
      tls: {}, // matches transit_encryption_enabled on the ElastiCache side
    })
  : null;

redis?.on("error", (err) => {
  // A cache outage must never take the app down with it — every call below
  // already catches and logs individually, this just stops ioredis's own
  // unhandled 'error' event from crashing the process between calls.
  console.error("Redis connection error:", err.message);
});

export const BALANCE_CACHE_TTL_SECONDS = 300;

// Per (group, user), not just per group — the response includes net_paisa
// scoped to whichever user is asking (routes/balances.ts's PAIRWISE_QUERY
// sibling query filters WHERE user_id = the requester), so a group-only key
// would serve one member's own net balance to a different member.
export function groupBalanceCacheKey(groupId: string, userId: string): string {
  return `balances:group:${groupId}:user:${userId}`;
}

export function userBalanceSummaryCacheKey(userId: string): string {
  return `balances:summary:${userId}`;
}

export async function getCached<T>(key: string): Promise<T | null> {
  if (!redis) return null;
  try {
    const value = await redis.get(key);
    return value ? (JSON.parse(value) as T) : null;
  } catch (err) {
    console.error(`Redis GET failed for ${key}:`, err instanceof Error ? err.message : err);
    return null;
  }
}

export async function setCached(key: string, value: unknown, ttlSeconds: number): Promise<void> {
  if (!redis) return;
  try {
    await redis.set(key, JSON.stringify(value), "EX", ttlSeconds);
  } catch (err) {
    console.error(`Redis SET failed for ${key}:`, err instanceof Error ? err.message : err);
  }
}

// Caught and logged here, not thrown — a Redis hiccup must not turn an
// already-successful database write into a failed HTTP request for the
// caller. The TTL above is what bounds the damage of a missed invalidation;
// the log line is what makes it visible rather than silent (same
// fire-and-continue shape as publishEventNotification's own failure
// handling in sqs.ts).
export async function invalidate(...keys: string[]): Promise<void> {
  if (!redis || keys.length === 0) return;
  try {
    await redis.del(...keys);
  } catch (err) {
    console.error(`Redis DEL failed for [${keys.join(", ")}]:`, err instanceof Error ? err.message : err);
  }
}

// Every affected user's group-balance entry (their own net_paisa in this
// group) and cross-group summary — called from routes/expenses.ts and
// routes/settlements.ts after every write that can change who owes what.
// The single source of truth for "which keys does this write touch," so the
// two call sites can't drift apart on what counts as affected.
export function invalidateBalanceCaches(
  groupId: string,
  affectedUserIds: Iterable<string>,
): Promise<void> {
  const keys = [...affectedUserIds].flatMap((id) => [
    groupBalanceCacheKey(groupId, id),
    userBalanceSummaryCacheKey(id),
  ]);
  return invalidate(...keys);
}
