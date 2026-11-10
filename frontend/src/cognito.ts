// Thin wrapper around Cognito's IDP JSON API, called directly from the
// browser — no Hosted UI, no redirect. These are unauthenticated,
// public operations keyed only by ClientId (no AWS credentials needed),
// so a raw fetch() is enough; pulling in the full
// @aws-sdk/client-cognito-identity-provider package just for these five
// calls would add a lot of bundle weight for no real benefit.
const REGION = import.meta.env.VITE_COGNITO_REGION as string;
const CLIENT_ID = import.meta.env.VITE_COGNITO_CLIENT_ID as string;
const ENDPOINT = `https://cognito-idp.${REGION}.amazonaws.com/`;

async function cognitoRequest<T>(target: string, body: Record<string, unknown>): Promise<T> {
  const response = await fetch(ENDPOINT, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-amz-json-1.1",
      "X-Amz-Target": `AWSCognitoIdentityProviderService.${target}`,
    },
    body: JSON.stringify(body),
  });

  const json = await response.json();
  if (!response.ok) {
    // Cognito's error shape: { "__type": "NotAuthorizedException", "message": "..." }
    const err = json as { __type?: string; message?: string };
    throw new Error(err.message || err.__type || `Cognito request failed: ${response.status}`);
  }
  return json as T;
}

export interface AuthenticationResult {
  AccessToken: string;
  IdToken: string;
  RefreshToken: string;
  ExpiresIn: number;
  TokenType: string;
}

interface InitiateAuthResponse {
  AuthenticationResult?: AuthenticationResult;
  ChallengeName?: string;
}

async function initiateAuth(
  authFlow: "USER_PASSWORD_AUTH" | "REFRESH_TOKEN_AUTH",
  authParameters: Record<string, string>,
): Promise<AuthenticationResult> {
  const response = await cognitoRequest<InitiateAuthResponse>("InitiateAuth", {
    AuthFlow: authFlow,
    ClientId: CLIENT_ID,
    AuthParameters: authParameters,
  });

  if (!response.AuthenticationResult) {
    // e.g. a SOFTWARE_TOKEN_MFA challenge — MFA is optional pool-wide and
    // no current sign-ins exercise it. Surfacing a clear error here rather
    // than silently failing; full challenge-response UI is a follow-up.
    throw new Error(
      `Unsupported sign-in challenge: ${response.ChallengeName ?? "unknown"}`,
    );
  }
  return response.AuthenticationResult;
}

export function signIn(email: string, password: string): Promise<AuthenticationResult> {
  return initiateAuth("USER_PASSWORD_AUTH", { USERNAME: email, PASSWORD: password });
}

export function refreshTokens(refreshToken: string): Promise<AuthenticationResult> {
  return initiateAuth("REFRESH_TOKEN_AUTH", { REFRESH_TOKEN: refreshToken });
}

// The pool's alias_attributes include "email" (modules/identity/main.tf),
// which makes email a lookup alias rather than the real, permanent
// Username — Cognito rejects an email-shaped Username at SignUp itself
// specifically to avoid that ambiguity ("cannot be of email format, since
// user pool is configured for email alias"). Sign-in works fine with the
// email alias (that's the whole point of alias_attributes), but
// ConfirmSignUp/ResendConfirmationCode need the real Username — an email
// alias isn't reliably resolvable before the account is confirmed, which
// is exactly the step these two calls are for. So the real, generated
// Username has to be returned here and threaded through by the caller.
export async function signUp(email: string, password: string): Promise<string> {
  const username = crypto.randomUUID();
  await cognitoRequest("SignUp", {
    ClientId: CLIENT_ID,
    Username: username,
    Password: password,
    UserAttributes: [{ Name: "email", Value: email }],
  });
  return username;
}

export async function confirmSignUp(username: string, code: string): Promise<void> {
  await cognitoRequest("ConfirmSignUp", {
    ClientId: CLIENT_ID,
    Username: username,
    ConfirmationCode: code,
  });
}

export async function resendConfirmationCode(username: string): Promise<void> {
  await cognitoRequest("ResendConfirmationCode", {
    ClientId: CLIENT_ID,
    Username: username,
  });
}
