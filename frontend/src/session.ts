import { refreshTokens, type AuthenticationResult } from "./cognito";

// localStorage (not memory-only) so a session survives a tab close/reopen —
// refresh token validity is already 30 days on the Cognito app client, so
// there's no reason to force a re-login every browser restart. Tradeoff:
// tokens are readable by any script on the page (XSS exposure) — acceptable
// here since there's no more sensitive alternative (no backend session to
// fall back on now that auth is Bearer-token-based, not cookie-based).
const STORAGE_KEY = "hisaab.session";

interface StoredSession {
  idToken: string;
  refreshToken: string;
  // Epoch ms. Refreshed proactively a minute before this to avoid a request
  // racing against expiry mid-flight.
  expiresAt: number;
}

function readSession(): StoredSession | null {
  const raw = localStorage.getItem(STORAGE_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as StoredSession;
  } catch {
    return null;
  }
}

function writeSession(result: AuthenticationResult): void {
  const session: StoredSession = {
    idToken: result.IdToken,
    refreshToken: result.RefreshToken,
    expiresAt: Date.now() + result.ExpiresIn * 1000,
  };
  localStorage.setItem(STORAGE_KEY, JSON.stringify(session));
}

// Called after a successful signIn() with the full AuthenticationResult.
export function startSession(result: AuthenticationResult): void {
  writeSession(result);
}

export function signOut(): void {
  localStorage.removeItem(STORAGE_KEY);
}

const REFRESH_SKEW_MS = 60_000;

// Returns null if there's no session at all, or if the refresh token itself
// has expired/been revoked (refreshTokens() throwing) — either way, the
// caller treats that as "not signed in."
export async function getIdToken(): Promise<string | null> {
  const session = readSession();
  if (!session) return null;

  if (Date.now() < session.expiresAt - REFRESH_SKEW_MS) {
    return session.idToken;
  }

  try {
    const result = await refreshTokens(session.refreshToken);
    // REFRESH_TOKEN_AUTH doesn't return a new RefreshToken — the original
    // one stays valid until its own (30-day) expiry.
    writeSession({ ...result, RefreshToken: session.refreshToken });
    return result.IdToken;
  } catch {
    signOut();
    return null;
  }
}
