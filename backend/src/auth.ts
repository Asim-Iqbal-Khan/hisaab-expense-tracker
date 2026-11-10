import { CognitoJwtVerifier } from "aws-jwt-verify";
import type { NextFunction, Request, Response } from "express";
import { config } from "./config";

declare global {
  namespace Express {
    interface Request {
      cognitoSub?: string;
    }
  }
}

// Real Cognito ID tokens — standard RFC 7519 JWTs, URL-safe base64,
// verifiable against the pool's own JWKS. Unlike the ALB-signed
// x-amzn-oidc-data token this replaced (a different trust root, encoded
// with a non-standard base64 alphabet that forced hand-rolled
// verification), aws-jwt-verify's CognitoJwtVerifier is purpose-built for
// exactly this case: it fetches and caches the JWKS itself, checks
// signature/exp/iss/token_use/aud, and gives back the decoded payload.
const verifier = CognitoJwtVerifier.create({
  userPoolId: config.cognitoUserPoolId,
  tokenUse: "id",
  clientId: config.cognitoAppClientId,
});

export async function requireAuth(req: Request, res: Response, next: NextFunction) {
  if (config.devBypassAuth) {
    // Optional override so local testing can act as more than one seeded
    // user without restarting the process — never reachable outside the
    // devBypassAuth branch itself.
    const devSub = req.headers["x-dev-cognito-sub"];
    req.cognitoSub = typeof devSub === "string" ? devSub : "dev-local-user";
    next();
    return;
  }

  const authHeader = req.headers.authorization;
  if (typeof authHeader !== "string" || !authHeader.startsWith("Bearer ")) {
    res.status(401).json({ error: "Missing bearer token" });
    return;
  }
  const token = authHeader.slice("Bearer ".length);

  try {
    const payload = await verifier.verify(token);
    req.cognitoSub = payload.sub;
    next();
  } catch (err) {
    console.error("requireAuth rejected request:", err instanceof Error ? err.message : err);
    res.status(401).json({ error: "Invalid or missing identity" });
  }
}
