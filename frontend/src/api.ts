import { getIdToken } from "./session";

export interface Profile {
  id: string;
  username: string;
  display_name: string;
  email: string;
  avatar_s3_key: string | null;
  created_at: string;
  // True while `username` is still the auto-generated fallback (not
  // collected at signup — set later from the Home page).
  needs_username: boolean;
}

// Every call below routes through this — attaches the Cognito ID token as a
// Bearer header instead of the old cookie-based `credentials: "include"`.
// A missing/expired session (getIdToken() returns null) still makes the
// request without an Authorization header, so the backend's normal 401
// handling applies rather than this helper inventing its own.
async function apiFetch(path: string, init: RequestInit = {}): Promise<Response> {
  const idToken = await getIdToken();
  const headers = new Headers(init.headers);
  if (idToken) {
    headers.set("Authorization", `Bearer ${idToken}`);
  }
  return fetch(path, { ...init, headers });
}

// A 401 here just means "not signed in" — no more ALB-redirect-to-Hosted-UI
// detection needed, since there's no redirect-based auth anymore.
export async function fetchMe(): Promise<Profile | null> {
  const response = await apiFetch("/api/me");

  if (response.status === 401) {
    return null;
  }
  if (!response.ok) {
    throw new Error(`Failed to fetch profile: ${response.status}`);
  }

  return response.json();
}

export async function setUsername(username: string): Promise<Profile> {
  const response = await apiFetch("/api/me/username", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username }),
  });
  if (!response.ok) {
    const body = await response.json().catch(() => null);
    throw new Error((body as { error?: string } | null)?.error ?? `Failed to set username: ${response.status}`);
  }
  return response.json();
}

export interface Group {
  id: string;
  name: string;
  created_by: string;
  created_at: string;
  net_paisa: string;
}

export interface GroupMember {
  id: string;
  username: string;
  display_name: string;
  avatar_s3_key: string | null;
  joined_at: string;
}

export interface GroupInvitationSummary {
  id: string;
  invitee_id: string;
  invitee_username: string;
  invitee_display_name: string;
  invited_by: string;
  created_at: string;
}

export interface GroupDetail extends Group {
  members: GroupMember[];
  pending_invitations: GroupInvitationSummary[];
}

export interface SearchResultUser {
  id: string;
  username: string;
  display_name: string;
  avatar_s3_key: string | null;
}

export interface MyInvitation {
  id: string;
  group_id: string;
  group_name: string;
  invited_by: string;
  inviter_username: string;
  inviter_display_name: string;
  created_at: string;
}

async function parseJsonOrThrow<T>(response: Response, action: string): Promise<T> {
  if (!response.ok) {
    const body = await response.json().catch(() => null);
    throw new Error((body as { error?: string } | null)?.error ?? `${action}: ${response.status}`);
  }
  return response.json();
}

export async function listGroups(): Promise<Group[]> {
  const response = await apiFetch("/api/groups");
  return parseJsonOrThrow(response, "Failed to load groups");
}

export async function createGroup(name: string): Promise<Group> {
  const response = await apiFetch("/api/groups", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name }),
  });
  return parseJsonOrThrow(response, "Failed to create group");
}

export async function getGroup(groupId: string): Promise<GroupDetail> {
  const response = await apiFetch(`/api/groups/${groupId}`);
  return parseJsonOrThrow(response, "Failed to load group");
}

export async function leaveGroup(groupId: string): Promise<void> {
  const response = await apiFetch(`/api/groups/${groupId}/leave`, {
    method: "POST",
  });
  if (!response.ok) {
    await parseJsonOrThrow(response, "Failed to leave group");
  }
}

export async function deleteGroup(groupId: string): Promise<void> {
  const response = await apiFetch(`/api/groups/${groupId}`, {
    method: "DELETE",
  });
  if (!response.ok) {
    await parseJsonOrThrow(response, "Failed to delete group");
  }
}

export async function searchGroupUsers(groupId: string, q: string): Promise<SearchResultUser[]> {
  const response = await apiFetch(
    `/api/groups/${groupId}/user-search?q=${encodeURIComponent(q)}`,
  );
  return parseJsonOrThrow(response, "Search failed");
}

export async function inviteUser(groupId: string, inviteeUserId: string): Promise<void> {
  const response = await apiFetch(`/api/groups/${groupId}/invitations`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ inviteeUserId }),
  });
  if (!response.ok) {
    await parseJsonOrThrow(response, "Failed to send invitation");
  }
}

export async function listMyInvitations(): Promise<MyInvitation[]> {
  const response = await apiFetch("/api/invitations");
  return parseJsonOrThrow(response, "Failed to load invitations");
}

export async function acceptInvitation(invitationId: string): Promise<void> {
  const response = await apiFetch(`/api/invitations/${invitationId}/accept`, {
    method: "POST",
  });
  if (!response.ok) {
    await parseJsonOrThrow(response, "Failed to accept invitation");
  }
}

export async function rejectInvitation(invitationId: string): Promise<void> {
  const response = await apiFetch(`/api/invitations/${invitationId}/reject`, {
    method: "POST",
  });
  if (!response.ok) {
    await parseJsonOrThrow(response, "Failed to reject invitation");
  }
}

export async function cancelInvitation(invitationId: string): Promise<void> {
  const response = await apiFetch(`/api/invitations/${invitationId}`, {
    method: "DELETE",
  });
  if (!response.ok) {
    await parseJsonOrThrow(response, "Failed to cancel invitation");
  }
}

export interface ExpenseSplit {
  user_id: string;
  share_paisa: string;
  username: string;
  display_name: string;
}

export interface Expense {
  id: string;
  group_id: string;
  description: string;
  amount_paisa: string;
  paid_by: string;
  created_by: string;
  paid_by_username: string;
  paid_by_display_name: string;
  expense_date: string;
  created_at: string;
  splits: ExpenseSplit[];
}

export interface ExpenseInput {
  description: string;
  amountPaisa: number;
  expenseDate: string;
  paidBy: string;
  splitUserIds: string[];
}

// pg returns bigint/int8 columns (amount_paisa, share_paisa, net_paisa) as
// strings to avoid precision loss — these two are the one place that
// boundary gets crossed, so every rupee<->paisa conversion in the UI should
// go through them rather than inlining /100 or *100 elsewhere.
export function paisaToRupees(paisa: string): number {
  return Number(paisa) / 100;
}

export function rupeesToPaisa(rupees: number): number {
  return Math.round(rupees * 100);
}

export async function listExpenses(groupId: string): Promise<Expense[]> {
  const response = await apiFetch(`/api/groups/${groupId}/expenses`);
  return parseJsonOrThrow(response, "Failed to load expenses");
}

export async function getExpense(groupId: string, expenseId: string): Promise<Expense> {
  const response = await apiFetch(`/api/groups/${groupId}/expenses/${expenseId}`, {
  });
  return parseJsonOrThrow(response, "Failed to load expense");
}

export async function createExpense(groupId: string, input: ExpenseInput): Promise<Expense> {
  const response = await apiFetch(`/api/groups/${groupId}/expenses`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  return parseJsonOrThrow(response, "Failed to create expense");
}

export async function updateExpense(
  groupId: string,
  expenseId: string,
  input: ExpenseInput,
): Promise<void> {
  const response = await apiFetch(`/api/groups/${groupId}/expenses/${expenseId}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!response.ok) {
    await parseJsonOrThrow(response, "Failed to update expense");
  }
}

export async function deleteExpense(groupId: string, expenseId: string): Promise<void> {
  const response = await apiFetch(`/api/groups/${groupId}/expenses/${expenseId}`, {
    method: "DELETE",
  });
  if (!response.ok) {
    await parseJsonOrThrow(response, "Failed to delete expense");
  }
}

export interface PairwiseBalance {
  user_a_id: string;
  user_a_username: string | null;
  user_a_display_name: string | null;
  user_a_active: boolean;
  user_b_id: string;
  user_b_username: string | null;
  user_b_display_name: string | null;
  user_b_active: boolean;
  // Positive: user_a owes user_b. Negative: user_b owes user_a.
  amount_paisa: string;
}

export interface GroupBalances {
  net_paisa: string;
  pairwise: PairwiseBalance[];
}

export interface BalanceDetailExpense {
  id: string;
  description: string;
  amount_paisa: string;
  paid_by: string;
  expense_date: string;
  share_paisa: string;
}

export interface BalanceDetailSettlement {
  id: string;
  from_user_id: string;
  to_user_id: string;
  amount_paisa: string;
  note: string | null;
  created_at: string;
}

export interface BalanceDetail {
  expenses: BalanceDetailExpense[];
  settlements: BalanceDetailSettlement[];
}

export interface BalanceSummary {
  owed_to_user_paisa: string;
  owed_by_user_paisa: string;
}

export async function getGroupBalances(groupId: string): Promise<GroupBalances> {
  const response = await apiFetch(`/api/groups/${groupId}/balances`);
  return parseJsonOrThrow(response, "Failed to load balances");
}

export async function getPairwiseDetail(
  groupId: string,
  userA: string,
  userB: string,
): Promise<BalanceDetail> {
  const response = await apiFetch(
    `/api/groups/${groupId}/balances/detail?userA=${encodeURIComponent(userA)}&userB=${encodeURIComponent(userB)}`,
  );
  return parseJsonOrThrow(response, "Failed to load balance detail");
}

export async function getBalanceSummary(): Promise<BalanceSummary> {
  const response = await apiFetch("/api/balances/summary");
  return parseJsonOrThrow(response, "Failed to load balance summary");
}

export interface Settlement {
  id: string;
  from_user_id: string;
  to_user_id: string;
  amount_paisa: string;
  note: string | null;
  created_at: string;
  from_username: string;
  from_display_name: string;
  to_username: string;
  to_display_name: string;
}

export interface RecordSettlementInput {
  counterpartyUserId: string;
  direction: "i_paid" | "i_received";
  amountPaisa: number;
  note?: string;
}

export async function listSettlements(groupId: string): Promise<Settlement[]> {
  const response = await apiFetch(`/api/groups/${groupId}/settlements`);
  return parseJsonOrThrow(response, "Failed to load settlements");
}

export async function recordSettlement(
  groupId: string,
  input: RecordSettlementInput,
): Promise<Settlement> {
  const response = await apiFetch(`/api/groups/${groupId}/settlements`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  return parseJsonOrThrow(response, "Failed to record settlement");
}

export async function deleteSettlement(groupId: string, settlementId: string): Promise<void> {
  const response = await apiFetch(`/api/groups/${groupId}/settlements/${settlementId}`, {
    method: "DELETE",
  });
  if (!response.ok) {
    await parseJsonOrThrow(response, "Failed to delete settlement");
  }
}

export interface ActivityEvent {
  id: string;
  actor_id: string;
  event_type:
    | "member_joined"
    | "member_left"
    | "expense_added"
    | "expense_edited"
    | "expense_deleted"
    | "settlement_recorded"
    | "settlement_deleted";
  payload: Record<string, unknown>;
  created_at: string;
}

export interface ActivityUserInfo {
  username: string;
  display_name: string;
}

export interface ActivityPage {
  events: ActivityEvent[];
  users: Record<string, ActivityUserInfo>;
  has_more: boolean;
}

export async function getActivity(groupId: string, before?: string): Promise<ActivityPage> {
  const query = before ? `?before=${encodeURIComponent(before)}` : "";
  const response = await apiFetch(`/api/groups/${groupId}/activity${query}`);
  return parseJsonOrThrow(response, "Failed to load activity");
}

export interface NotificationPrefs {
  notify_events: boolean;
  notify_reminder: boolean;
}

export async function getNotificationPrefs(): Promise<NotificationPrefs> {
  const response = await apiFetch("/api/me/notification-prefs");
  return parseJsonOrThrow(response, "Failed to load notification preferences");
}

export async function updateNotificationPrefs(
  updates: Partial<Pick<NotificationPrefs, "notify_events" | "notify_reminder">>,
): Promise<void> {
  const response = await apiFetch("/api/me/notification-prefs", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(updates),
  });
  if (!response.ok) {
    await parseJsonOrThrow(response, "Failed to update notification preferences");
  }
}

