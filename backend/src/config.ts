function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

export const config = {
  port: Number(process.env.PORT ?? 8080),
  dbHost: required("DB_HOST"),
  dbPort: Number(process.env.DB_PORT ?? 5432),
  dbName: required("DB_NAME"),
  dbSecretJson: required("DB_SECRET_JSON"),
  // RDS requires SSL; a plain local Postgres (the .env.example DB_HOST=localhost
  // setup) typically doesn't have it configured. Defaults to on so the real
  // deployed app.env (which never sets this) is unaffected.
  dbSsl: process.env.DB_SSL !== "0",
  awsRegion: required("AWS_REGION"),
  cognitoUserPoolId: required("COGNITO_USER_POOL_ID"),
  cognitoAppClientId: required("COGNITO_APP_CLIENT_ID"),
  sqsQueueUrl: required("SQS_QUEUE_URL"),
  // Deliberately optional, unlike everything else above — the balance
  // cache (cache.ts) treats a missing REDIS_HOST as "caching disabled" and
  // falls through to the database, so local dev never needs a real Redis
  // instance running. The deployed app.env always sets this.
  redisHost: process.env.REDIS_HOST,
  redisPort: Number(process.env.REDIS_PORT ?? 6379),
  // Local-dev-only escape hatch — never set in the deployed app.env. Lets
  // requireAuth skip ALB header verification (which only ever succeeds
  // behind the real load balancer) so routes/queries/UI can be iterated on
  // without redeploying. Must never be true outside a developer's shell.
  devBypassAuth: process.env.DEV_BYPASS_AUTH === "1",
};
