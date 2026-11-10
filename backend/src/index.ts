import express from "express";
import { config } from "./config";
import { healthRouter } from "./routes/health";
import { meRouter } from "./routes/me";
import { groupsRouter } from "./routes/groups";
import { invitationsRouter } from "./routes/invitations";
import { expensesRouter } from "./routes/expenses";
import { balancesRouter } from "./routes/balances";
import { settlementsRouter } from "./routes/settlements";
import { activityRouter } from "./routes/activity";
import { notificationsRouter } from "./routes/notifications";

// No CORS middleware: CloudFront proxies /api/* to the ALB under the same
// origin as the frontend (see modules/delivery), so browser requests to
// this API are same-origin. Auth itself is Bearer-token-based now (the
// frontend talks to Cognito directly and attaches the token), not
// cookie-based, so same-origin isn't required for auth to work — it's just
// kept because it avoids adding CORS handling for no functional gain.
const app = express();

app.use(express.json());

app.use(healthRouter);
app.use(meRouter);
app.use(groupsRouter);
app.use(invitationsRouter);
app.use(expensesRouter);
app.use(balancesRouter);
app.use(settlementsRouter);
app.use(activityRouter);
app.use(notificationsRouter);

app.listen(config.port, () => {
  console.log(`hisaab-api listening on :${config.port}`);
});
