// Standalone local test for requireAuth's ALB token verification — no AWS,
// no ALB, no Cognito. Generates a throwaway ES256 keypair, crafts a token
// shaped exactly like ALB's x-amzn-oidc-data (standard base64 padding, raw
// ieee-p1363 signature), and runs it through the real requireAuth
// middleware with global.fetch stubbed to serve our own test public key
// instead of hitting the real public-keys.auth.elb.* endpoint.
import { createSign, generateKeyPairSync } from "crypto";
import type { Request, Response } from "express";
import { config } from "../src/config";
import { requireAuth } from "../src/auth";

const { publicKey, privateKey } = generateKeyPairSync("ec", {
  namedCurve: "prime256v1",
  publicKeyEncoding: { type: "spki", format: "pem" },
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
});

const kid = "test-kid-123";
const keyUrl = `https://public-keys.auth.elb.${config.awsRegion}.amazonaws.com/${kid}`;

const realFetch = global.fetch;
global.fetch = (async (url: string | URL, ...rest: unknown[]) => {
  if (url.toString() === keyUrl) {
    return { ok: true, text: async () => publicKey } as Response;
  }
  return realFetch(url as string, ...(rest as []));
}) as typeof fetch;

function b64(obj: unknown): string {
  return Buffer.from(JSON.stringify(obj)).toString("base64");
}

function sign(signingInput: string): Buffer {
  return createSign("SHA256").update(signingInput).sign({ key: privateKey, dsaEncoding: "ieee-p1363" });
}

function buildToken(payload: Record<string, unknown>, opts?: { corruptSignature?: boolean; signer?: string }): string {
  const header = { alg: "ES256", kid, signer: opts?.signer ?? config.albArn };
  const headerSeg = b64(header);
  const payloadSeg = b64(payload);
  const signature = sign(`${headerSeg}.${payloadSeg}`);
  const finalSignature = opts?.corruptSignature
    ? Buffer.concat([Buffer.from([signature[0] ^ 0xff]), signature.subarray(1)])
    : signature;
  return `${headerSeg}.${payloadSeg}.${finalSignature.toString("base64")}`;
}

function fakeReqRes(token: string) {
  const req = { headers: { "x-amzn-oidc-data": token } } as unknown as Request;
  let statusCode = 0;
  let body: unknown = null;
  const res = {
    status(code: number) {
      statusCode = code;
      return this;
    },
    json(payload: unknown) {
      body = payload;
      return this;
    },
  } as unknown as Response;
  let nextCalled = false;
  const next = () => {
    nextCalled = true;
  };
  return { req, res, next, result: () => ({ statusCode, body, nextCalled }) };
}

async function main() {
  let failures = 0;

  const valid = fakeReqRes(buildToken({ sub: "test-user-sub-123" }));
  await requireAuth(valid.req, valid.res, valid.next);
  const validResult = valid.result();
  const validPass = validResult.nextCalled && (valid.req as Request & { cognitoSub?: string }).cognitoSub === "test-user-sub-123";
  console.log(`[valid token]        ${validPass ? "PASS" : "FAIL"} ${JSON.stringify(validResult)}`);
  if (!validPass) failures++;

  const tampered = fakeReqRes(buildToken({ sub: "test-user-sub-456" }, { corruptSignature: true }));
  await requireAuth(tampered.req, tampered.res, tampered.next);
  const tamperedResult = tampered.result();
  const tamperedPass = !tamperedResult.nextCalled && tamperedResult.statusCode === 401;
  console.log(`[tampered signature] ${tamperedPass ? "PASS" : "FAIL"} ${JSON.stringify(tamperedResult)}`);
  if (!tamperedPass) failures++;

  const wrongSigner = fakeReqRes(
    buildToken({ sub: "test-user-sub-789" }, { signer: "arn:aws:elasticloadbalancing:us-west-2:999999999999:loadbalancer/app/not-us/xyz" }),
  );
  await requireAuth(wrongSigner.req, wrongSigner.res, wrongSigner.next);
  const wrongSignerResult = wrongSigner.result();
  const wrongSignerPass = !wrongSignerResult.nextCalled && wrongSignerResult.statusCode === 401;
  console.log(`[wrong signer]       ${wrongSignerPass ? "PASS" : "FAIL"} ${JSON.stringify(wrongSignerResult)}`);
  if (!wrongSignerPass) failures++;

  if (failures > 0) {
    console.error(`\n${failures} check(s) failed`);
    process.exit(1);
  }
  console.log("\nAll checks passed — requireAuth's decode/verify logic is structurally correct.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
