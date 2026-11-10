-- Hisaab — PostgreSQL schema
-- Target: PostgreSQL 16
-- Revision 2: explicit FK actions, composite membership integrity, ledger views
--
-- CORE INVARIANTS (see notes at the bottom of each section):
--   1. All money is integer paisa. No floats anywhere.
--   2. Users are never hard-deleted. Account removal = anonymisation in place.
--   3. group_members rows are never DELETEd. Leaving sets left_at.
--   4. Financial rows are soft-deleted (deleted_at), never removed.
--   5. Balances are derived from views, never stored.

CREATE EXTENSION IF NOT EXISTS citext;


-- ============================================================================
-- Enumerated types
-- ============================================================================
-- Enums over `text` so a typo is a constraint violation, not a silent bug.
-- Growth is handled with ALTER TYPE ... ADD VALUE, which is cheap.
-- Values can be added but not removed, which is the correct bias for audit data.

CREATE TYPE invitation_status AS ENUM (
    'pending',
    'accepted',
    'rejected',
    'cancelled'
);

CREATE TYPE activity_type AS ENUM (
    'member_joined',
    'member_left',
    'expense_added',
    'expense_edited',
    'expense_deleted',
    'settlement_recorded',
    'settlement_deleted'
);


-- ============================================================================
-- users
-- ============================================================================
-- Mirrors the Cognito user pool. cognito_sub is the join key; username mirrors
-- Cognito's preferred_username, which Cognito already enforces as unique.
--
-- Deletion policy: NEVER. Every other table references users with RESTRICT.
-- Account removal is anonymisation: scrub display_name and email, set
-- anonymised_at, leave the row and all financial history intact. Deleting a
-- user who holds a balance would silently corrupt every counterparty's books.

CREATE TABLE users (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    cognito_sub    text        NOT NULL UNIQUE,
    username       citext      NOT NULL UNIQUE,
    display_name   text        NOT NULL,
    email          citext      NOT NULL UNIQUE,
    avatar_s3_key  text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    anonymised_at  timestamptz,

    CONSTRAINT users_username_format
        CHECK (username ~ '^[a-z0-9_]{3,20}$'),
    CONSTRAINT users_display_name_length
        CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 50)
);


-- ============================================================================
-- user_notification_prefs
-- ============================================================================
-- Split out of `users` for two reasons. First, separation of concerns: identity
-- and delivery preferences change on completely different schedules. Second and
-- more practically, last_reminded_at is UPDATEd by the weekly reminder job for
-- every indebted user. Keeping that churn off the users table avoids bloating a
-- row that is otherwise near-static and heavily read.
--
-- This is the one place a users FK cascades: preferences carry no financial
-- value and are meaningless without their user.

CREATE TABLE user_notification_prefs (
    user_id          uuid        PRIMARY KEY
                                 REFERENCES users(id) ON DELETE CASCADE,
    notify_events    boolean     NOT NULL DEFAULT true,
    notify_reminder  boolean     NOT NULL DEFAULT true,
    last_reminded_at timestamptz,
    updated_at       timestamptz NOT NULL DEFAULT now()
);

-- No subscription/confirmation bookkeeping here (SQS + SES, not SNS) — the API
-- and fn-reminder-dispatcher enqueue {to, subject, body} directly, resolving
-- the recipient's email from `users` at send time. Nothing to confirm.


-- ============================================================================
-- groups
-- ============================================================================

CREATE TABLE groups (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text        NOT NULL,
    created_by  uuid        NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    deleted_at  timestamptz,

    CONSTRAINT groups_name_length
        CHECK (char_length(btrim(name)) BETWEEN 1 AND 50)
);


-- ============================================================================
-- group_members
-- ============================================================================
-- Natural composite primary key. The surrogate `id` in revision 1 bought
-- nothing and cost an extra column plus an index.
--
-- The PK on (group_id, user_id) is doing double duty: it is also the unique
-- index that the composite foreign keys on expenses, expense_splits and
-- settlements target. That is what lets the database enforce "you can only
-- split an expense with someone who is actually in the group".
--
-- CRITICAL: never DELETE from this table. Leaving a group sets left_at.
-- A deleted membership row would either cascade away the member's expense
-- history or block the delete forever. Soft-leaving keeps the FK target alive
-- so historical splits stay valid. Rejoining sets left_at back to NULL, which
-- is why the PK is unconditional rather than partial.

CREATE TABLE group_members (
    group_id   uuid        NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id    uuid        NOT NULL REFERENCES users(id)  ON DELETE RESTRICT,
    joined_at  timestamptz NOT NULL DEFAULT now(),
    left_at    timestamptz,

    PRIMARY KEY (group_id, user_id),

    CONSTRAINT group_members_left_after_joined
        CHECK (left_at IS NULL OR left_at >= joined_at)
);


-- ============================================================================
-- group_invitations
-- ============================================================================

CREATE TABLE group_invitations (
    id           uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id     uuid              NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    invitee_id   uuid              NOT NULL REFERENCES users(id)  ON DELETE RESTRICT,
    invited_by   uuid              NOT NULL REFERENCES users(id)  ON DELETE RESTRICT,
    status       invitation_status NOT NULL DEFAULT 'pending',
    created_at   timestamptz       NOT NULL DEFAULT now(),
    responded_at timestamptz,

    CONSTRAINT invitations_no_self_invite
        CHECK (invitee_id <> invited_by),

    -- responded_at and status must agree. Without this you get 'accepted' rows
    -- with a NULL response time, and nobody notices for months.
    CONSTRAINT invitations_response_consistency
        CHECK (
            (status =  'pending' AND responded_at IS NULL) OR
            (status <> 'pending' AND responded_at IS NOT NULL)
        )
);

-- One live invitation per (group, invitee), but any number of historical
-- rejected or cancelled ones. A partial unique index expresses exactly that;
-- a plain UNIQUE would forbid re-inviting someone who declined.
CREATE UNIQUE INDEX group_invitations_one_pending
    ON group_invitations (group_id, invitee_id)
    WHERE status = 'pending';


-- ============================================================================
-- expenses
-- ============================================================================
-- Two things worth noting.
--
-- 1. UNIQUE (id, group_id) looks pointless because id is already the PK. It
--    exists solely as the target for the composite FK from expense_splits,
--    which is how "a split belongs to the same group as its expense" becomes a
--    database constraint rather than an application convention.
--
-- 2. FK (group_id, paid_by) -> group_members means the payer must be a member.
--    It cascades, but only ever fires on genuine group teardown, because
--    group_members rows are never deleted in normal operation (see above).
--
-- expense_date must not be in the future. That is enforced in the application,
-- not here: a CHECK referencing CURRENT_DATE is not immutable and will fail
-- revalidation on dump/restore.

CREATE TABLE expenses (
    id             uuid        NOT NULL DEFAULT gen_random_uuid(),
    group_id       uuid        NOT NULL,
    description    text        NOT NULL,
    amount_paisa   bigint      NOT NULL,
    paid_by        uuid        NOT NULL,
    expense_date   date        NOT NULL,
    receipt_s3_key text,
    created_by     uuid        NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    deleted_at     timestamptz,

    PRIMARY KEY (id),
    UNIQUE (id, group_id),

    FOREIGN KEY (group_id)
        REFERENCES groups(id) ON DELETE CASCADE,
    FOREIGN KEY (group_id, paid_by)
        REFERENCES group_members(group_id, user_id) ON DELETE CASCADE,

    CONSTRAINT expenses_amount_positive
        CHECK (amount_paisa > 0),
    CONSTRAINT expenses_description_length
        CHECK (char_length(btrim(description)) BETWEEN 1 AND 140)
);


-- ============================================================================
-- expense_splits
-- ============================================================================
-- group_id here is deliberate redundancy, and it is the point of this table's
-- design. It cannot drift, because the two composite foreign keys below make
-- any inconsistent value impossible to insert. In exchange, the database now
-- enforces an invariant that no single-column FK can express:
--
--     a split's user is a member of the split's expense's group
--
-- Without it, nothing stops you splitting a flatmates expense with someone who
-- is only in your Naran trip group.
--
-- Composite PK: (expense_id, user_id). One share per person per expense.

CREATE TABLE expense_splits (
    expense_id  uuid   NOT NULL,
    group_id    uuid   NOT NULL,
    user_id     uuid   NOT NULL,
    share_paisa bigint NOT NULL,

    PRIMARY KEY (expense_id, user_id),

    FOREIGN KEY (expense_id, group_id)
        REFERENCES expenses(id, group_id) ON DELETE CASCADE,
    FOREIGN KEY (group_id, user_id)
        REFERENCES group_members(group_id, user_id) ON DELETE CASCADE,

    CONSTRAINT expense_splits_share_positive
        CHECK (share_paisa > 0)
);


-- ============================================================================
-- settlements
-- ============================================================================
-- Both parties are constrained to group membership by composite FKs, the same
-- way expenses constrains its payer.

CREATE TABLE settlements (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id     uuid        NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    from_user_id uuid        NOT NULL,
    to_user_id   uuid        NOT NULL,
    amount_paisa bigint      NOT NULL,
    note         text,
    created_by   uuid        NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at   timestamptz NOT NULL DEFAULT now(),
    deleted_at   timestamptz,

    FOREIGN KEY (group_id, from_user_id)
        REFERENCES group_members(group_id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (group_id, to_user_id)
        REFERENCES group_members(group_id, user_id) ON DELETE CASCADE,

    CONSTRAINT settlements_amount_positive
        CHECK (amount_paisa > 0),
    CONSTRAINT settlements_no_self_payment
        CHECK (from_user_id <> to_user_id),
    CONSTRAINT settlements_note_length
        CHECK (note IS NULL OR char_length(note) <= 140)
);


-- ============================================================================
-- activity_events
-- ============================================================================
-- Two changes from revision 1.
--
-- 1. The polymorphic (entity_type, entity_id) pair is replaced with real
--    nullable foreign keys plus a CHECK that at most one is set. A polymorphic
--    column cannot have a foreign key, so those rows were free to point at
--    nothing. Now they can't.
--
-- 2. bigint identity instead of uuid. This table is append-only and grows
--    faster than everything else combined. A monotonic key gives sequential
--    index inserts instead of random B-tree pages, and doubles as the natural
--    pagination cursor for the feed.
--
-- payload jsonb stays denormalised on purpose. It is a snapshot of how the
-- event looked when it happened, so the feed still renders "Ali added Dinner,
-- Rs 3,000" after the expense is edited to Rs 3,500. That is the intended
-- behaviour of an audit log, not a normalisation failure.
--
-- The entity FKs use SET NULL rather than CASCADE: if an expense is ever hard
-- deleted, the event survives as history with its payload snapshot intact.

CREATE TABLE activity_events (
    id              bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    group_id        uuid          NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    actor_id        uuid          NOT NULL REFERENCES users(id)  ON DELETE RESTRICT,
    event_type      activity_type NOT NULL,
    expense_id      uuid          REFERENCES expenses(id)    ON DELETE SET NULL,
    settlement_id   uuid          REFERENCES settlements(id) ON DELETE SET NULL,
    subject_user_id uuid          REFERENCES users(id)       ON DELETE RESTRICT,
    payload         jsonb         NOT NULL DEFAULT '{}'::jsonb,
    created_at      timestamptz   NOT NULL DEFAULT now(),

    CONSTRAINT activity_single_subject
        CHECK (num_nonnulls(expense_id, settlement_id, subject_user_id) <= 1)
);


-- ============================================================================
-- The one invariant SQL cannot express declaratively
-- ============================================================================
-- "Split shares sum exactly to the expense amount" spans multiple rows, so no
-- CHECK constraint can enforce it. A deferred constraint trigger can: it fires
-- at COMMIT, after every split for the expense has been inserted, so a normal
-- multi-row insert inside one transaction passes.
--
-- Without this, a rounding bug produces balances that never reach zero and
-- members who can therefore never leave a group. That failure is silent and
-- surfaces weeks later as "the maths is wrong", which is the worst possible
-- bug in a money app.

CREATE OR REPLACE FUNCTION assert_split_sum_matches_expense()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_expense_id uuid;
    v_amount     bigint;
    v_sum        bigint;
BEGIN
    v_expense_id := COALESCE(NEW.expense_id, OLD.expense_id);

    SELECT amount_paisa INTO v_amount
    FROM expenses WHERE id = v_expense_id;

    -- Expense itself was removed in this transaction; splits cascaded away.
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT COALESCE(SUM(share_paisa), 0) INTO v_sum
    FROM expense_splits WHERE expense_id = v_expense_id;

    IF v_sum <> v_amount THEN
        RAISE EXCEPTION
            'split shares total % paisa but expense % is % paisa',
            v_sum, v_expense_id, v_amount
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_expense_splits_sum
    AFTER INSERT OR UPDATE OR DELETE ON expense_splits
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION assert_split_sum_matches_expense();

-- Also fires when the expense amount itself changes.
CREATE OR REPLACE FUNCTION assert_expense_amount_matches_splits()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_sum bigint;
BEGIN
    SELECT COALESCE(SUM(share_paisa), 0) INTO v_sum
    FROM expense_splits WHERE expense_id = NEW.id;

    -- No splits yet: the expense row was just inserted, splits follow.
    IF v_sum = 0 THEN
        RETURN NULL;
    END IF;

    IF v_sum <> NEW.amount_paisa THEN
        RAISE EXCEPTION
            'expense % is % paisa but its splits total % paisa',
            NEW.id, NEW.amount_paisa, v_sum
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_expenses_amount_sum
    AFTER INSERT OR UPDATE OF amount_paisa ON expenses
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION assert_expense_amount_matches_splits();


-- ============================================================================
-- updated_at maintenance
-- ============================================================================

CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_users_touch
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TRIGGER trg_groups_touch
    BEFORE UPDATE ON groups
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TRIGGER trg_expenses_touch
    BEFORE UPDATE ON expenses
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TRIGGER trg_prefs_touch
    BEFORE UPDATE ON user_notification_prefs
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();


-- ============================================================================
-- Balance views
-- ============================================================================
-- Balances are derived, never stored. These views are the only sanctioned way
-- to compute them. Querying the base tables directly for balances is how you
-- eventually forget a `deleted_at IS NULL` filter and ship a silent money bug.
--
-- Sign convention: positive means the user is OWED money.
--   paid for an expense      -> +amount   (money went out of their pocket)
--   owes a share             -> -share
--   sent a settlement        -> +amount   (their debt shrinks)
--   received a settlement    -> -amount

CREATE VIEW v_ledger_entries AS
    SELECT e.group_id, e.paid_by AS user_id, e.amount_paisa AS delta_paisa
    FROM expenses e
    WHERE e.deleted_at IS NULL

    UNION ALL

    SELECT s.group_id, s.user_id, -s.share_paisa
    FROM expense_splits s
    JOIN expenses e ON e.id = s.expense_id
    WHERE e.deleted_at IS NULL

    UNION ALL

    SELECT st.group_id, st.from_user_id, st.amount_paisa
    FROM settlements st
    WHERE st.deleted_at IS NULL

    UNION ALL

    SELECT st.group_id, st.to_user_id, -st.amount_paisa
    FROM settlements st
    WHERE st.deleted_at IS NULL;


CREATE VIEW v_net_balances AS
    SELECT group_id,
           user_id,
           SUM(delta_paisa) AS net_paisa
    FROM v_ledger_entries
    GROUP BY group_id, user_id;

-- Assertion for the test suite and a periodic health check:
-- every group's net positions must sum to exactly zero.
--
--   SELECT group_id, SUM(net_paisa)
--   FROM v_net_balances
--   GROUP BY group_id
--   HAVING SUM(net_paisa) <> 0;
--
-- Any row returned means the ledger is corrupt. This should be a monitored
-- query, not just a test.


-- ============================================================================
-- Pairwise balance view
-- ============================================================================
-- v_ledger_entries/v_net_balances answer "what's my total in this group" — the
-- counterparty is netted away in the process, so neither can answer "who
-- specifically owes whom." This view keeps that dimension instead of discarding
-- it, same per-entry shape and same filtering rules as v_ledger_entries (the
-- whole reason this is a view and not an inline query in application code:
-- one authoritative place for "how to filter for balance correctness," not a
-- second reimplementation that can silently drift from the first).

CREATE VIEW v_pairwise_ledger AS
    -- An expense split's user (debtor) owes the payer (creditor) their share.
    -- The payer's own split row, if they're in their own split, is excluded —
    -- self-debt is meaningless and would otherwise show debtor = creditor.
    SELECT e.group_id, es.user_id AS debtor, e.paid_by AS creditor, es.share_paisa AS amount_paisa
    FROM expense_splits es
    JOIN expenses e ON e.id = es.expense_id
    WHERE e.deleted_at IS NULL AND es.user_id <> e.paid_by

    UNION ALL

    -- A settlement (from_user_id sends amount_paisa to to_user_id) is the
    -- reverse-direction edge: paying down a debt is the structural inverse of
    -- incurring one. debtor=to_user_id, creditor=from_user_id here makes
    -- summing per-user reduce to exactly v_ledger_entries' settlement rows
    -- (from_user_id nets +amount, to_user_id nets -amount).
    SELECT s.group_id, s.to_user_id AS debtor, s.from_user_id AS creditor, s.amount_paisa
    FROM settlements s
    WHERE s.deleted_at IS NULL;

-- Deliberately does NOT filter on group_members.left_at: a departed member can
-- still have a real, nonzero pairwise balance with someone even though the
-- group's own leave-check (see application code) only verifies their
-- *aggregate* net was zero at the time they left. Those debts don't vanish
-- just because membership lapsed — callers must surface them, not filter them
-- out, and label the counterparty as departed for display.


-- ============================================================================
-- Indexes
-- ============================================================================
-- Composite primary keys already cover the leading-column lookups, so these
-- are the reverse-direction and filtered access paths.

CREATE INDEX idx_group_members_user
    ON group_members (user_id)
    WHERE left_at IS NULL;

CREATE INDEX idx_invitations_invitee_pending
    ON group_invitations (invitee_id)
    WHERE status = 'pending';

CREATE INDEX idx_expenses_group_date
    ON expenses (group_id, expense_date DESC)
    WHERE deleted_at IS NULL;

CREATE INDEX idx_expenses_paid_by
    ON expenses (group_id, paid_by)
    WHERE deleted_at IS NULL;

CREATE INDEX idx_expense_splits_user
    ON expense_splits (group_id, user_id);

CREATE INDEX idx_settlements_group
    ON settlements (group_id, created_at DESC)
    WHERE deleted_at IS NULL;

CREATE INDEX idx_settlements_from
    ON settlements (group_id, from_user_id)
    WHERE deleted_at IS NULL;

CREATE INDEX idx_settlements_to
    ON settlements (group_id, to_user_id)
    WHERE deleted_at IS NULL;

CREATE INDEX idx_activity_group_recent
    ON activity_events (group_id, id DESC);

CREATE INDEX idx_prefs_reminder_due
    ON user_notification_prefs (last_reminded_at)
    WHERE notify_reminder = true;


-- ============================================================================
-- Foreign key action summary
-- ============================================================================
--
--   Child                       Parent               ON DELETE   Reasoning
--   --------------------------- -------------------- ----------- --------------------------------
--   user_notification_prefs     users                CASCADE     no financial value
--   groups.created_by           users                RESTRICT    users are never deleted
--   group_members.user_id       users                RESTRICT    holds balance history
--   group_members.group_id      groups               CASCADE     teardown only
--   group_invitations.*         users                RESTRICT    uniform user policy
--   group_invitations.group_id  groups               CASCADE     teardown only
--   expenses.group_id           groups               CASCADE     teardown only
--   expenses.(group_id,paid_by) group_members        CASCADE     safe: memberships never deleted
--   expenses.created_by         users                RESTRICT    uniform user policy
--   expense_splits -> expenses  expenses             CASCADE     a share cannot outlive its expense
--   expense_splits -> members   group_members        CASCADE     safe: memberships never deleted
--   settlements.group_id        groups               CASCADE     teardown only
--   settlements.(from|to)       group_members        CASCADE     safe: memberships never deleted
--   settlements.created_by      users                RESTRICT    uniform user policy
--   activity_events.group_id    groups               CASCADE     teardown only
--   activity_events.actor_id    users                RESTRICT    audit trail must name someone
--   activity_events.expense_id  expenses             SET NULL    event survives as history
--   activity_events.settlement  settlements          SET NULL    event survives as history
--
-- The CASCADEs onto group_members are only safe because of invariant 3: those
-- rows are never DELETEd, only marked with left_at. If anyone ever writes a
-- DELETE against group_members, it will silently destroy expense history.
-- Enforce this in code review, and consider a REVOKE DELETE on the table for
-- the application role.
