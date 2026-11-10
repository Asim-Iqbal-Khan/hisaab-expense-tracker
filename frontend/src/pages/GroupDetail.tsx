import { useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { ChevronDown, ChevronUp, Pencil, Plus, Trash2 } from "lucide-react";
import {
  cancelInvitation,
  deleteExpense,
  deleteGroup,
  deleteSettlement,
  fetchMe,
  getActivity,
  getGroup,
  getGroupBalances,
  getPairwiseDetail,
  inviteUser,
  leaveGroup,
  listExpenses,
  listSettlements,
  paisaToRupees,
  searchGroupUsers,
  type ActivityEvent,
  type ActivityUserInfo,
  type BalanceDetail,
  type Expense,
  type GroupBalances,
  type GroupDetail as GroupDetailData,
  type PairwiseBalance,
  type Profile,
  type SearchResultUser,
  type Settlement,
} from "../api";
import { signOut } from "../session";
import { Layout } from "../components/Layout";
import { Modal } from "../components/Modal";
import { ExpenseForm } from "../components/ExpenseForm";
import { SettlementForm } from "../components/SettlementForm";

const cardClass = "rounded-lg border border-gray-200 bg-white p-4 shadow-sm";
const primaryBtn =
  "inline-flex items-center gap-1.5 rounded-md bg-indigo-600 px-3 py-1.5 text-sm font-medium text-white shadow-sm hover:bg-indigo-500 disabled:opacity-50";
const secondaryBtn =
  "inline-flex items-center gap-1.5 rounded-md border border-gray-300 bg-white px-3 py-1.5 text-sm font-medium text-gray-700 shadow-sm hover:bg-gray-50 disabled:opacity-50";
const iconBtn = "text-gray-400 hover:text-gray-600";
const dangerIconBtn = "text-gray-400 hover:text-rose-600";
const inputClass =
  "block w-full rounded-md border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500";

interface SettlePrefill {
  counterpartyUserId: string;
  counterpartyLabel: string;
  direction: "i_paid" | "i_received";
  amountPaisa?: number;
}

function settlePrefillFromPair(pw: PairwiseBalance, myId: string | undefined): SettlePrefill | null {
  const aOwesB = Number(pw.amount_paisa) > 0;
  const debtorId = aOwesB ? pw.user_a_id : pw.user_b_id;
  if (myId !== pw.user_a_id && myId !== pw.user_b_id) {
    return null;
  }
  const counterparty = myId === pw.user_a_id
    ? { id: pw.user_b_id, name: pw.user_b_display_name, active: pw.user_b_active }
    : { id: pw.user_a_id, name: pw.user_a_display_name, active: pw.user_a_active };
  return {
    counterpartyUserId: counterparty.id,
    counterpartyLabel: personLabel(counterparty.name, counterparty.active),
    direction: debtorId === myId ? "i_paid" : "i_received",
    amountPaisa: Math.abs(Number(pw.amount_paisa)),
  };
}

function personLabel(name: string | null, active: boolean): string {
  const base = name ?? "Someone";
  return active ? base : `${base} (left group)`;
}

// amount_paisa positive means user_a owes user_b; negative means the reverse.
// Rendered as "<debtor> owe(s) <creditor> Rs X", using "You" when the current
// viewer is one side of the pair.
function describePair(pw: PairwiseBalance, myId: string | undefined) {
  const aOwesB = Number(pw.amount_paisa) > 0;
  const debtor = aOwesB
    ? { id: pw.user_a_id, name: pw.user_a_display_name, active: pw.user_a_active }
    : { id: pw.user_b_id, name: pw.user_b_display_name, active: pw.user_b_active };
  const creditor = aOwesB
    ? { id: pw.user_b_id, name: pw.user_b_display_name, active: pw.user_b_active }
    : { id: pw.user_a_id, name: pw.user_a_display_name, active: pw.user_a_active };
  const magnitude = Math.abs(Number(pw.amount_paisa)) / 100;
  const isMeDebtor = debtor.id === myId;
  const debtorLabel = isMeDebtor ? "You" : personLabel(debtor.name, debtor.active);
  const creditorLabel = creditor.id === myId ? "you" : personLabel(creditor.name, creditor.active);
  const verb = isMeDebtor ? "owe" : "owes";
  return `${debtorLabel} ${verb} ${creditorLabel} Rs ${magnitude.toFixed(2)}`;
}

function activityUserLabel(id: unknown, users: Record<string, ActivityUserInfo>): string {
  if (typeof id !== "string") return "Someone";
  return users[id]?.display_name ?? "Someone";
}

function rupees(paisa: unknown): string {
  return typeof paisa === "string" ? paisaToRupees(paisa).toFixed(2) : "0.00";
}

// Only worth stating when it's not obvious — i.e. someone other than the
// actor was the payer (adding/editing/deleting an expense on someone
// else's behalf, a case this app explicitly supports).
function payerSuffix(paidBy: unknown, actorId: string, users: Record<string, ActivityUserInfo>): string {
  if (typeof paidBy !== "string" || paidBy === actorId) return "";
  return ` — paid by ${activityUserLabel(paidBy, users)}`;
}

// Renders one activity_events row into a single human-readable line. The
// actor's name is resolved live (via the `users` map from the API response)
// — safe, since there's nothing about "who someone currently is" that needs
// freezing — while every other field (description, amount, before/after) is
// read straight from the event's own payload snapshot, never re-fetched.
function describeActivity(event: ActivityEvent, users: Record<string, ActivityUserInfo>): string {
  const actor = activityUserLabel(event.actor_id, users);
  const p = event.payload as Record<string, unknown>;

  switch (event.event_type) {
    case "member_joined":
      return `${actor} joined the group`;
    case "member_left":
      return `${actor} left the group`;
    case "expense_added":
      return `${actor} added "${p.description}" (Rs ${rupees(p.amount_paisa)})${payerSuffix(p.paid_by, event.actor_id, users)}`;
    case "expense_deleted":
      return `${actor} deleted "${p.description}" (Rs ${rupees(p.amount_paisa)})${payerSuffix(p.paid_by, event.actor_id, users)}`;
    case "expense_edited": {
      const before = (p.before ?? {}) as Record<string, unknown>;
      const after = (p.after ?? {}) as Record<string, unknown>;
      const changes: string[] = [];
      if (before.description !== after.description) {
        changes.push(`"${before.description}" → "${after.description}"`);
      }
      if (before.amount_paisa !== after.amount_paisa) {
        changes.push(`Rs ${rupees(before.amount_paisa)} → Rs ${rupees(after.amount_paisa)}`);
      }
      if (before.paid_by !== after.paid_by) {
        changes.push(
          `paid by ${activityUserLabel(before.paid_by, users)} → ${activityUserLabel(after.paid_by, users)}`,
        );
      }
      return `${actor} edited an expense${changes.length ? ` (${changes.join(", ")})` : ""}`;
    }
    case "settlement_recorded": {
      const from = activityUserLabel(p.from_user_id, users);
      const to = activityUserLabel(p.to_user_id, users);
      return `${actor} recorded: ${from} paid ${to} Rs ${rupees(p.amount_paisa)}`;
    }
    case "settlement_deleted": {
      const from = activityUserLabel(p.from_user_id, users);
      const to = activityUserLabel(p.to_user_id, users);
      return `${actor} deleted a settlement: ${from} paid ${to} Rs ${rupees(p.amount_paisa)}`;
    }
    default:
      return `${actor} did something`;
  }
}

export function GroupDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();

  const [group, setGroup] = useState<GroupDetailData | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [expenses, setExpenses] = useState<Expense[]>([]);
  const [balances, setBalances] = useState<GroupBalances | null>(null);
  const [settlements, setSettlements] = useState<Settlement[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [showSettleForm, setShowSettleForm] = useState(false);
  const [settlePrefill, setSettlePrefill] = useState<SettlePrefill | null>(null);

  const [expandedPair, setExpandedPair] = useState<string | null>(null);
  const [pairDetail, setPairDetail] = useState<BalanceDetail | null>(null);
  const [loadingDetail, setLoadingDetail] = useState(false);

  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SearchResultUser[]>([]);
  const [searching, setSearching] = useState(false);

  const [showAddExpense, setShowAddExpense] = useState(false);
  const [editingExpense, setEditingExpense] = useState<Expense | null>(null);

  const [activityEvents, setActivityEvents] = useState<ActivityEvent[]>([]);
  const [activityUsers, setActivityUsers] = useState<Record<string, ActivityUserInfo>>({});
  const [activityHasMore, setActivityHasMore] = useState(false);
  const [loadingMoreActivity, setLoadingMoreActivity] = useState(false);

  function load() {
    if (!id) return;
    setLoading(true);
    Promise.all([
      getGroup(id),
      fetchMe(),
      listExpenses(id),
      getGroupBalances(id),
      listSettlements(id),
      getActivity(id),
    ])
      .then(([g, p, e, b, s, a]) => {
        setGroup(g);
        setProfile(p);
        setExpenses(e);
        setBalances(b);
        setSettlements(s);
        setActivityEvents(a.events);
        setActivityUsers(a.users);
        setActivityHasMore(a.has_more);
        setError(null);
      })
      .catch((err) => setError(err instanceof Error ? err.message : String(err)))
      .finally(() => setLoading(false));
  }

  useEffect(load, [id]);

  useEffect(() => {
    if (!id || query.trim().length < 3) {
      setResults([]);
      return;
    }
    setSearching(true);
    const timeout = setTimeout(() => {
      searchGroupUsers(id, query.trim())
        .then(setResults)
        .catch((err) => setError(err instanceof Error ? err.message : String(err)))
        .finally(() => setSearching(false));
    }, 300);
    return () => clearTimeout(timeout);
  }, [id, query]);

  function handleLogout() {
    signOut();
    navigate("/");
  }

  async function handleInvite(userId: string) {
    if (!id) return;
    try {
      await inviteUser(id, userId);
      setQuery("");
      setResults([]);
      load();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function handleCancelInvitation(invitationId: string) {
    try {
      await cancelInvitation(invitationId);
      load();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function toggleExpand(pw: PairwiseBalance) {
    const key = `${pw.user_a_id}-${pw.user_b_id}`;
    if (expandedPair === key) {
      setExpandedPair(null);
      setPairDetail(null);
      return;
    }
    if (!id) return;
    setExpandedPair(key);
    setPairDetail(null);
    setLoadingDetail(true);
    try {
      const detail = await getPairwiseDetail(id, pw.user_a_id, pw.user_b_id);
      setPairDetail(detail);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoadingDetail(false);
    }
  }

  async function handleDeleteSettlement(settlementId: string) {
    if (!id) return;
    if (!window.confirm("Delete this settlement?")) return;
    try {
      await deleteSettlement(id, settlementId);
      load();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function handleLoadMoreActivity() {
    if (!id || activityEvents.length === 0) return;
    setLoadingMoreActivity(true);
    try {
      const lastId = activityEvents[activityEvents.length - 1].id;
      const page = await getActivity(id, lastId);
      setActivityEvents((prev) => [...prev, ...page.events]);
      setActivityUsers((prev) => ({ ...prev, ...page.users }));
      setActivityHasMore(page.has_more);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoadingMoreActivity(false);
    }
  }

  async function handleDeleteExpense(expenseId: string) {
    if (!id) return;
    if (!window.confirm("Delete this expense?")) return;
    try {
      await deleteExpense(id, expenseId);
      load();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function handleLeave() {
    if (!id) return;
    if (!window.confirm("Leave this group?")) return;
    try {
      await leaveGroup(id);
      navigate("/groups");
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function handleDelete() {
    if (!id) return;
    if (!window.confirm("Delete this group? This cannot be undone.")) return;
    try {
      await deleteGroup(id);
      navigate("/groups");
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center text-gray-400">Loading…</div>
    );
  }
  if (error) {
    return (
      <div className="flex min-h-screen items-center justify-center px-4">
        <p className="text-rose-600">Error: {error}</p>
      </div>
    );
  }
  if (!group) {
    return (
      <div className="flex min-h-screen items-center justify-center text-gray-500">
        Group not found.
      </div>
    );
  }

  return (
    <Layout userDisplayName={profile?.display_name} onLogout={handleLogout}>
      <Link to="/groups" className="text-sm text-indigo-600 hover:text-indigo-500">
        ← Groups
      </Link>
      <h1 className="mt-1 text-2xl font-bold text-gray-900">{group.name}</h1>

      {/* Members */}
      <section className="mt-6">
        <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-gray-500">Members</h2>
        <div className="flex flex-wrap gap-2">
          {group.members.map((member) => (
            <span
              key={member.id}
              className="rounded-full border border-gray-200 bg-white px-3 py-1 text-sm text-gray-700 shadow-sm"
            >
              {member.display_name} <span className="text-gray-400">@{member.username}</span>
            </span>
          ))}
        </div>
      </section>

      {/* Balances */}
      <section className="mt-6">
        <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-gray-500">Balances</h2>
        {balances && (
          <>
            <p className="mb-3 text-sm">
              Your net position:{" "}
              <span
                className={
                  Number(balances.net_paisa) > 0
                    ? "font-semibold text-emerald-600"
                    : Number(balances.net_paisa) < 0
                      ? "font-semibold text-rose-600"
                      : "font-semibold text-gray-500"
                }
              >
                Rs {paisaToRupees(balances.net_paisa).toFixed(2)}
              </span>{" "}
              <span className="text-gray-400">
                (
                {Number(balances.net_paisa) > 0
                  ? "you are owed"
                  : Number(balances.net_paisa) < 0
                    ? "you owe"
                    : "settled up"}
                )
              </span>
            </p>

            {balances.pairwise.length === 0 && <p className="text-sm text-gray-500">No outstanding balances.</p>}

            <ul className="flex flex-col gap-2">
              {balances.pairwise.map((pw) => {
                const key = `${pw.user_a_id}-${pw.user_b_id}`;
                const isExpanded = expandedPair === key;
                const canSettle = profile?.id === pw.user_a_id || profile?.id === pw.user_b_id;
                return (
                  <li key={key} className={cardClass}>
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <p className="text-sm text-gray-700">{describePair(pw, profile?.id)}</p>
                      <div className="flex items-center gap-2">
                        {canSettle && (
                          <button
                            className={secondaryBtn}
                            onClick={() => {
                              const prefill = settlePrefillFromPair(pw, profile?.id);
                              if (prefill) {
                                setSettlePrefill(prefill);
                                setShowSettleForm(false);
                              }
                            }}
                          >
                            Settle up
                          </button>
                        )}
                        <button
                          className={iconBtn}
                          onClick={() => toggleExpand(pw)}
                          aria-label={isExpanded ? "Hide details" : "Show details"}
                        >
                          {isExpanded ? <ChevronUp size={18} /> : <ChevronDown size={18} />}
                        </button>
                      </div>
                    </div>
                    {isExpanded && (
                      <div className="mt-3 border-t border-gray-100 pt-3">
                        {loadingDetail && <p className="text-sm text-gray-400">Loading…</p>}
                        {pairDetail && (
                          <ul className="flex flex-col gap-1 text-sm text-gray-600">
                            {pairDetail.expenses.map((exp) => (
                              <li key={`e-${exp.id}`}>
                                {exp.expense_date} — {exp.description}: Rs{" "}
                                {paisaToRupees(exp.share_paisa).toFixed(2)} share of Rs{" "}
                                {paisaToRupees(exp.amount_paisa).toFixed(2)}
                              </li>
                            ))}
                            {pairDetail.settlements.map((s) => (
                              <li key={`s-${s.id}`}>
                                {s.created_at} — settlement: Rs {paisaToRupees(s.amount_paisa).toFixed(2)}
                                {s.note ? ` (${s.note})` : ""}
                              </li>
                            ))}
                            {pairDetail.expenses.length === 0 && pairDetail.settlements.length === 0 && (
                              <li>Nothing on record.</li>
                            )}
                          </ul>
                        )}
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          </>
        )}

        {!showSettleForm && !settlePrefill && (
          <button className={`${secondaryBtn} mt-3`} onClick={() => setShowSettleForm(true)}>
            Record a settlement
          </button>
        )}
      </section>

      {id && (showSettleForm || settlePrefill) && (
        <Modal
          onClose={() => {
            setShowSettleForm(false);
            setSettlePrefill(null);
          }}
        >
          <SettlementForm
            groupId={id}
            activeMembers={group.members}
            currentUserId={profile?.id}
            prefill={settlePrefill ?? undefined}
            onSaved={() => {
              setShowSettleForm(false);
              setSettlePrefill(null);
              load();
            }}
            onCancel={() => {
              setShowSettleForm(false);
              setSettlePrefill(null);
            }}
          />
        </Modal>
      )}

      {/* Settlement history */}
      <section className="mt-6">
        <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-gray-500">
          Settlement history
        </h2>
        <ul className="flex flex-col gap-2">
          {settlements.map((s) => (
            <li key={s.id} className={`${cardClass} flex items-center justify-between`}>
              <p className="text-sm text-gray-700">
                <span className="font-medium">{s.from_display_name}</span> paid{" "}
                <span className="font-medium">{s.to_display_name}</span>{" "}
                <span className="font-semibold text-emerald-600">
                  Rs {paisaToRupees(s.amount_paisa).toFixed(2)}
                </span>
                {s.note ? <span className="text-gray-400"> — {s.note}</span> : null}
              </p>
              {profile && (profile.id === s.from_user_id || profile.id === s.to_user_id) && (
                <button
                  className={dangerIconBtn}
                  onClick={() => handleDeleteSettlement(s.id)}
                  aria-label="Delete settlement"
                >
                  <Trash2 size={16} />
                </button>
              )}
            </li>
          ))}
        </ul>
        {settlements.length === 0 && <p className="text-sm text-gray-500">No settlements recorded yet.</p>}
      </section>

      {/* Expenses */}
      <section className="mt-6">
        <div className="mb-2 flex items-center justify-between">
          <h2 className="text-sm font-semibold uppercase tracking-wide text-gray-500">Expenses</h2>
          <button className={primaryBtn} onClick={() => setShowAddExpense(true)}>
            <Plus size={16} /> Add expense
          </button>
        </div>
        <ul className="flex flex-col gap-2">
          {expenses.map((expense) => (
            <li key={expense.id} className={`${cardClass} flex items-center justify-between`}>
              <p className="text-sm text-gray-700">
                <span className="font-medium">{expense.description}</span> —{" "}
                <span className="font-semibold text-gray-900">
                  Rs {paisaToRupees(expense.amount_paisa).toFixed(2)}
                </span>{" "}
                paid by {expense.paid_by_display_name}
                <span className="text-gray-400"> on {expense.expense_date}</span>
              </p>
              {profile && (profile.id === expense.created_by || profile.id === expense.paid_by) && (
                <span className="flex items-center gap-2">
                  <button
                    className={iconBtn}
                    onClick={() => {
                      setEditingExpense(expense);
                      setShowAddExpense(false);
                    }}
                    aria-label="Edit expense"
                  >
                    <Pencil size={16} />
                  </button>
                  <button
                    className={dangerIconBtn}
                    onClick={() => handleDeleteExpense(expense.id)}
                    aria-label="Delete expense"
                  >
                    <Trash2 size={16} />
                  </button>
                </span>
              )}
            </li>
          ))}
        </ul>
        {expenses.length === 0 && <p className="text-sm text-gray-500">No expenses yet.</p>}
      </section>

      {id && (showAddExpense || editingExpense) && (
        <Modal
          onClose={() => {
            setShowAddExpense(false);
            setEditingExpense(null);
          }}
        >
          <ExpenseForm
            groupId={id}
            activeMembers={group.members}
            existingExpense={editingExpense}
            onSaved={() => {
              setShowAddExpense(false);
              setEditingExpense(null);
              load();
            }}
            onCancel={() => {
              setShowAddExpense(false);
              setEditingExpense(null);
            }}
          />
        </Modal>
      )}

      {/* Invite */}
      <section className="mt-6">
        <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-gray-500">
          Invite someone
        </h2>
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search by username (min 3 characters)"
          className={inputClass}
        />
        {searching && <p className="mt-2 text-sm text-gray-400">Searching…</p>}
        {results.length > 0 && (
          <ul className="mt-2 flex flex-col gap-2">
            {results.map((user) => (
              <li key={user.id} className={`${cardClass} flex items-center justify-between`}>
                <span className="text-sm text-gray-700">
                  {user.display_name} <span className="text-gray-400">@{user.username}</span>
                </span>
                <button className={secondaryBtn} onClick={() => handleInvite(user.id)}>
                  Invite
                </button>
              </li>
            ))}
          </ul>
        )}
      </section>

      {group.pending_invitations.length > 0 && (
        <section className="mt-6">
          <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-gray-500">
            Pending invitations
          </h2>
          <ul className="flex flex-col gap-2">
            {group.pending_invitations.map((inv) => (
              <li key={inv.id} className={`${cardClass} flex items-center justify-between`}>
                <span className="text-sm text-gray-700">
                  {inv.invitee_display_name} <span className="text-gray-400">@{inv.invitee_username}</span>
                </span>
                {profile && inv.invited_by === profile.id && (
                  <button
                    className={dangerIconBtn}
                    onClick={() => handleCancelInvitation(inv.id)}
                    aria-label="Cancel invitation"
                  >
                    <Trash2 size={16} />
                  </button>
                )}
              </li>
            ))}
          </ul>
        </section>
      )}

      {/* Activity */}
      <section className="mt-6">
        <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-gray-500">Activity</h2>
        <ul className="flex flex-col gap-1">
          {activityEvents.map((event) => (
            <li key={event.id} className="text-sm text-gray-600">
              <span className="mr-2 text-gray-400">{new Date(event.created_at).toLocaleString()}</span>
              {describeActivity(event, activityUsers)}
            </li>
          ))}
        </ul>
        {activityEvents.length === 0 && <p className="text-sm text-gray-500">No activity yet.</p>}
        {activityHasMore && (
          <button
            className={`${secondaryBtn} mt-3`}
            onClick={handleLoadMoreActivity}
            disabled={loadingMoreActivity}
          >
            {loadingMoreActivity ? "Loading…" : "Load more"}
          </button>
        )}
      </section>

      <section className="mt-8 flex gap-2 border-t border-gray-200 pt-6">
        <button className={secondaryBtn} onClick={handleLeave}>
          Leave group
        </button>
        <button
          className="inline-flex items-center gap-1.5 rounded-md border border-rose-300 bg-white px-3 py-1.5 text-sm font-medium text-rose-600 shadow-sm hover:bg-rose-50"
          onClick={handleDelete}
        >
          Delete group
        </button>
      </section>
    </Layout>
  );
}
