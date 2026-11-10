# Hisaab — Product Requirements Document

**Version:** 0.1 (MVP)
**Status:** Feature scope locked, pending implementation
**Last updated:** 27 July 2026

---

## 1. Overview

Hisaab is a shared-expense tracker for small groups — flatmates, trip companions, office lunch circles. Members log who paid for what, the app keeps a running tally of who owes whom, and periodic reminders nudge people to settle their udhaar.

The app deliberately does not move money. It is a shared ledger and a nudge system. Actual payment happens outside the app, and one party records it.

### 1.1 Problem

Informal group expenses get tracked in WhatsApp threads and notes apps. Two things go wrong: the arithmetic drifts, and nobody wants to be the person who brings up the outstanding balance. Hisaab fixes the arithmetic and depersonalises the reminder.

### 1.2 Design principle

Every feature must sit on the core loop. If it doesn't, it is v2.

```
create group → invite members → log expense → balances update → settle up → get reminded
```

---

## 2. Goals and non-goals

### 2.1 Goals

| # | Goal | How we know it worked |
|---|---|---|
| G1 | Logging an expense takes under 15 seconds | Time from "add expense" tap to confirmation |
| G2 | Balances are always traceable to specific expenses | Every balance figure can be expanded to its source rows |
| G3 | Groups reach zero balance | % of groups older than 30 days with all balances settled |
| G4 | Reminders drive settlement, not annoyance | Settlement rate within 48h of reminder; notification opt-out rate |

### 2.2 Non-goals for v1

Explicitly not building, and not designing around:

- Multi-currency and FX conversion
- Real payments, bank integration, or payment gateways
- Receipt OCR or automatic expense parsing
- Unequal splits (exact amounts, percentages, shares)
- Recurring or scheduled expenses
- Debt simplification across the group
- Friend-to-friend balances outside of a group
- Comments or chat on expenses
- Expense categories, budgets, or spending analytics
- Offline mode and sync
- Inviting people who do not yet have an account

---

## 3. Personas

**The organiser.** Books the trip, pays the deposit, fronts most costs. Wants a defensible record and a low-friction way to ask for money back.

**The participant.** Shows up, pays for some things, loses track. Wants to know what they owe without doing arithmetic or feeling chased.

Both personas are the same user type in the system. No roles, no permissions tiers.

---

## 4. Feature specifications

### F1 — Authentication and profile

Cognito Hosted UI handles the entire auth surface. No custom auth screens.

**Scope**
- Sign up with email and password, email verification required
- Sign in, sign out, password reset
- Profile: unique username, display name, avatar image
- Avatar uploads to S3 via a pre-signed URL issued by the backend

**Acceptance criteria**
- A user cannot reach any group data without a valid Cognito JWT
- Username is unique, case-insensitive, 3–20 characters, `[a-z0-9_]` only
- Username is immutable after signup (avoids stale references and impersonation after handover)
- Display name is free text, changeable, non-unique
- A `users` row exists in RDS for every confirmed Cognito user, created by the Post Confirmation Lambda trigger
- Avatar files are private in S3; reads go through pre-signed GET URLs

### F2 — User search and group invitations

All invitees already have accounts. Invitations are in-app only.

**Scope**
- Search users by username (prefix match, minimum 3 characters)
- Invite a found user to a group
- Invitee sees pending invitations and accepts or rejects
- Inviter can cancel a pending invitation

**Acceptance criteria**
- Search results return username, display name, avatar URL only — never email
- Search excludes users already in the group and users with a pending invitation to it
- Search is rate-limited per user (suggested: 30 requests/minute)
- Any existing group member can invite; there is no admin tier in v1
- Accepting creates a `group_members` row and writes an activity event
- Rejecting sets status to `rejected` and writes no activity event — the group should not see who declined
- A rejected user can be invited again
- Only the original inviter may cancel a pending invitation
- Invitations do not expire in v1

### F3 — Groups

**Scope**
- Create a group with a name
- View group list with the user's net position in each
- View group detail: members, expenses, balances, activity
- Leave a group
- Delete a group

**Acceptance criteria**
- Group name is 1–50 characters, non-unique
- The creator is automatically the first member
- A member may leave only when their net balance in that group is exactly zero
- A group may be deleted only when every member's balance is zero
- Deleting a group is a soft delete
- Group size is capped at 20 members in v1
- Only members can read any group data

### F4 — Expenses

**Scope**
- Add an expense: description, amount, date, who paid, which members it is split between
- Equal split only — the amount divides evenly among the selected members
- Optional receipt image
- Edit an expense
- Delete an expense

**Acceptance criteria**
- Amount is stored as integer paisa; the API accepts and returns paisa
- Amount must be greater than zero
- Exactly one member is the payer; the payer need not be included in the split
- At least one member must be selected in the split
- The sum of split shares equals the expense amount exactly, always
- Remainder paisa from uneven division are distributed one each to the first N members by ascending `user_id` — deterministic, so the same input always yields the same split
- The expense date may be backdated but not future-dated
- Editing replaces the split rows and writes an activity event recording the change
- Deletion is a soft delete; balances recompute as if the expense never existed, but it stays visible in the activity feed as a deleted item
- Any member can edit or delete any expense in the group — trust model is social, not technical
- Receipt images upload to S3 by pre-signed URL, max 5 MB, JPEG/PNG/WebP only

### F5 — Balances

Balances are **derived**, never stored as a mutable column. They are computed from expense splits and settlements on read.

**Scope**
- Per-group pairwise balances: who owes whom, and how much
- Per-group net position for the current user
- Cross-group summary: total owed by the user, total owed to the user

**Acceptance criteria**
- Pairwise balances are netted per pair — if A owes B 1,000 and B owes A 400, the app shows a single "A owes B 600"
- No debt simplification: the app never suggests a payment between two members who have no shared expense history
- A pairwise balance can be expanded to show the expenses and settlements that produced it
- Net positions across all members of a group always sum to exactly zero
- Soft-deleted expenses and settlements are excluded from all balance computation
- Zero balances are hidden from the pairwise view

### F6 — Settle up

**Scope**
- Record a payment from one member to another
- Optional note
- View settlement history

**Acceptance criteria**
- A settlement is a ledger entry between exactly two members of the same group
- Amount must be greater than zero; it may exceed the outstanding balance (which flips the direction of the debt)
- Settlements may be created by either party — recording is on the honour system
- A settlement can be deleted (soft) but not edited; delete and re-record instead
- Recording a settlement writes an activity event and notifies the counterparty

### F7 — Activity feed

**Scope**
- Per-group reverse-chronological log of everything that changed

**Acceptance criteria**
- Events captured: member joined, member left, expense added, expense edited, expense deleted, settlement recorded, settlement deleted
- Each event stores the actor, the timestamp, and enough payload to render the line without joining to live data
- Events are immutable and are never deleted, even when the underlying entity is soft-deleted
- The feed is paginated

### F8 — Notifications

Delivery via SNS. Scheduled reminders via EventBridge → Lambda → SNS.

**Scope**
- Event-driven notifications
- Scheduled settlement reminders
- Per-user notification preferences

**Acceptance criteria**

Event-driven triggers:
- You were invited to a group
- An expense involving you was added
- Someone recorded a settlement with you

Scheduled reminder:
- Runs weekly
- Sent only to users with a non-zero outstanding balance they owe
- Summarises total owed across all groups in one message — never one message per group
- Suppressed if the user received a reminder within the last 7 days

Preferences:
- A single on/off toggle for event notifications, and a separate on/off for the weekly reminder
- Preferences are honoured before the message is published to SNS, not filtered afterwards

---

## 5. Invariants

These are the rules that keep the ledger trustworthy. Every one of them should have a test.

| # | Invariant |
|---|---|
| I1 | All money is stored as integer paisa. No floats, anywhere, ever. |
| I2 | Split shares always sum exactly to the expense amount. |
| I3 | Net positions of all members in a group always sum to exactly zero. |
| I4 | Balances are derived from the ledger on read, never stored and mutated. |
| I5 | Financial records are soft-deleted, never hard-deleted. |
| I6 | A member cannot leave a group with a non-zero balance. |
| I7 | Only group members can read group data; enforced at the query layer, not the UI. |

---

## 6. Data model sketch

Postgres on RDS. Types are indicative.

```
users
  id              uuid PK
  cognito_sub     text UNIQUE NOT NULL
  username        citext UNIQUE NOT NULL
  display_name    text NOT NULL
  email           text NOT NULL
  avatar_s3_key   text NULL
  notify_events   boolean NOT NULL DEFAULT true
  notify_reminder boolean NOT NULL DEFAULT true
  last_reminded_at timestamptz NULL
  created_at      timestamptz NOT NULL

groups
  id              uuid PK
  name            text NOT NULL
  created_by      uuid FK → users.id
  created_at      timestamptz NOT NULL
  deleted_at      timestamptz NULL

group_members
  id              uuid PK
  group_id        uuid FK → groups.id
  user_id         uuid FK → users.id
  joined_at       timestamptz NOT NULL
  UNIQUE (group_id, user_id)

group_invitations
  id              uuid PK
  group_id        uuid FK → groups.id
  invitee_id      uuid FK → users.id
  invited_by      uuid FK → users.id
  status          text NOT NULL   -- pending | accepted | rejected | cancelled
  created_at      timestamptz NOT NULL
  responded_at    timestamptz NULL
  partial UNIQUE (group_id, invitee_id) WHERE status = 'pending'

expenses
  id              uuid PK
  group_id        uuid FK → groups.id
  description     text NOT NULL
  amount_paisa    bigint NOT NULL CHECK (amount_paisa > 0)
  paid_by         uuid FK → users.id
  expense_date    date NOT NULL
  receipt_s3_key  text NULL
  created_by      uuid FK → users.id
  created_at      timestamptz NOT NULL
  updated_at      timestamptz NOT NULL
  deleted_at      timestamptz NULL

expense_splits
  id              uuid PK
  expense_id      uuid FK → expenses.id
  user_id         uuid FK → users.id
  share_paisa     bigint NOT NULL CHECK (share_paisa > 0)
  UNIQUE (expense_id, user_id)

settlements
  id              uuid PK
  group_id        uuid FK → groups.id
  from_user_id    uuid FK → users.id
  to_user_id      uuid FK → users.id
  amount_paisa    bigint NOT NULL CHECK (amount_paisa > 0)
  note            text NULL
  created_by      uuid FK → users.id
  created_at      timestamptz NOT NULL
  deleted_at      timestamptz NULL
  CHECK (from_user_id <> to_user_id)

activity_events
  id              uuid PK
  group_id        uuid FK → groups.id
  actor_id        uuid FK → users.id
  event_type      text NOT NULL
  entity_type     text NULL
  entity_id       uuid NULL
  payload         jsonb NOT NULL
  created_at      timestamptz NOT NULL
```

### 6.1 How balances are computed

For a member `u` in group `g`, net position is:

```
  + sum(expenses.amount_paisa where paid_by = u, not deleted)
  - sum(expense_splits.share_paisa where user_id = u, expense not deleted)
  + sum(settlements.amount_paisa where from_user_id = u, not deleted)
  - sum(settlements.amount_paisa where to_user_id = u, not deleted)
```

Positive means the user is owed money. Pairwise balances come from the same rows, grouped by the pair rather than the individual.

### 6.2 Indexes worth having from day one

- `group_members (user_id)` — powers the group list
- `expenses (group_id, expense_date DESC) WHERE deleted_at IS NULL`
- `expense_splits (user_id)`
- `activity_events (group_id, created_at DESC)`
- `group_invitations (invitee_id) WHERE status = 'pending'`

---

## 7. Open questions

1. **Reminder cadence.** Weekly is the assumption. Is that right for the target user, or is fortnightly less annoying?
2. **Receipt uploads.** Genuinely v1, or the first thing to cut if the timeline tightens? It is the only feature here that needs S3 for user content rather than static assets.
3. **Notification channel.** SNS to email is simplest. Is SMS in scope, given per-message cost and the need for phone verification?
4. **Group size cap.** 20 is a guess. Pairwise balance display gets noisy well before that — worth checking what the view looks like at 10.
5. **Invitation expiry.** Currently never. Does a stale pending invite from six months ago cause confusion?

---

## 8. Out of scope for this document

Infrastructure and delivery — RDS sizing, ECS/EC2 topology, autoscaling policy, Terraform module layout, CodePipeline stages, environment strategy — are covered separately once this feature set is signed off.
