import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { ChevronRight } from "lucide-react";
import {
  acceptInvitation,
  createGroup,
  fetchMe,
  getBalanceSummary,
  listGroups,
  listMyInvitations,
  paisaToRupees,
  rejectInvitation,
  type BalanceSummary,
  type Group,
  type MyInvitation,
  type Profile,
} from "../api";
import { signOut } from "../session";
import { Layout } from "../components/Layout";

export function Groups() {
  const navigate = useNavigate();
  const [groups, setGroups] = useState<Group[]>([]);
  const [invitations, setInvitations] = useState<MyInvitation[]>([]);
  const [summary, setSummary] = useState<BalanceSummary | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [newGroupName, setNewGroupName] = useState("");
  const [creating, setCreating] = useState(false);

  function load() {
    setLoading(true);
    Promise.all([listGroups(), listMyInvitations(), getBalanceSummary(), fetchMe()])
      .then(([g, i, s, p]) => {
        setGroups(g);
        setInvitations(i);
        setSummary(s);
        setProfile(p);
        setError(null);
      })
      .catch((err) => setError(err instanceof Error ? err.message : String(err)))
      .finally(() => setLoading(false));
  }

  useEffect(load, []);

  function handleLogout() {
    signOut();
    navigate("/");
  }

  async function handleCreate(e: React.FormEvent) {
    e.preventDefault();
    if (!newGroupName.trim()) return;
    setCreating(true);
    try {
      await createGroup(newGroupName.trim());
      setNewGroupName("");
      load();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setCreating(false);
    }
  }

  async function handleAccept(invitationId: string) {
    try {
      await acceptInvitation(invitationId);
      load();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function handleReject(invitationId: string) {
    try {
      await rejectInvitation(invitationId);
      load();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center text-gray-400">Loading…</div>
    );
  }

  return (
    <Layout userDisplayName={profile?.display_name} onLogout={handleLogout}>
      <h1 className="text-2xl font-bold text-gray-900">Groups</h1>
      {error && <p className="mt-2 text-sm text-rose-600">Error: {error}</p>}

      {summary && (
        <div className="mt-4 flex flex-col gap-2 rounded-lg border border-gray-200 bg-white p-4 shadow-sm sm:flex-row sm:justify-between">
          <p>
            <span className="text-gray-500">You owe</span>{" "}
            <span className="font-semibold text-rose-600">
              Rs {paisaToRupees(summary.owed_by_user_paisa).toFixed(2)}
            </span>
          </p>
          <p>
            <span className="text-gray-500">You are owed</span>{" "}
            <span className="font-semibold text-emerald-600">
              Rs {paisaToRupees(summary.owed_to_user_paisa).toFixed(2)}
            </span>
          </p>
        </div>
      )}

      {invitations.length > 0 && (
        <section className="mt-6">
          <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-gray-500">
            Pending invitations
          </h2>
          <ul className="flex flex-col gap-2">
            {invitations.map((inv) => (
              <li
                key={inv.id}
                className="flex items-center justify-between rounded-lg border border-gray-200 bg-white p-3 shadow-sm"
              >
                <span className="text-sm text-gray-700">
                  <span className="font-medium">{inv.inviter_display_name}</span> invited you to{" "}
                  <span className="font-medium">{inv.group_name}</span>
                </span>
                <span className="flex gap-2">
                  <button
                    onClick={() => handleAccept(inv.id)}
                    className="rounded-md bg-indigo-600 px-3 py-1.5 text-sm font-medium text-white shadow-sm hover:bg-indigo-500"
                  >
                    Accept
                  </button>
                  <button
                    onClick={() => handleReject(inv.id)}
                    className="rounded-md border border-gray-300 bg-white px-3 py-1.5 text-sm font-medium text-gray-700 shadow-sm hover:bg-gray-50"
                  >
                    Reject
                  </button>
                </span>
              </li>
            ))}
          </ul>
        </section>
      )}

      <form onSubmit={handleCreate} className="mt-6 flex gap-2">
        <input
          value={newGroupName}
          onChange={(e) => setNewGroupName(e.target.value)}
          placeholder="New group name"
          maxLength={50}
          className="block w-full rounded-md border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
        />
        <button
          type="submit"
          disabled={creating || !newGroupName.trim()}
          className="shrink-0 rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-indigo-500 disabled:opacity-50"
        >
          Create group
        </button>
      </form>

      <ul className="mt-4 flex flex-col gap-2">
        {groups.map((group) => {
          const net = Number(group.net_paisa);
          return (
            <li key={group.id}>
              <Link
                to={`/groups/${group.id}`}
                className="flex items-center justify-between rounded-lg border border-gray-200 bg-white p-4 shadow-sm hover:border-indigo-300 hover:shadow"
              >
                <span className="font-medium text-gray-900">{group.name}</span>
                <span className="flex items-center gap-2">
                  <span
                    className={
                      net === 0
                        ? "text-sm text-gray-400"
                        : net > 0
                          ? "text-sm font-medium text-emerald-600"
                          : "text-sm font-medium text-rose-600"
                    }
                  >
                    Rs {paisaToRupees(group.net_paisa).toFixed(2)}
                  </span>
                  <ChevronRight size={18} className="text-gray-300" />
                </span>
              </Link>
            </li>
          );
        })}
      </ul>
      {groups.length === 0 && <p className="mt-4 text-gray-500">You're not in any groups yet.</p>}
    </Layout>
  );
}
