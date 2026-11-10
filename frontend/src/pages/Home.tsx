import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import {
  fetchMe,
  setUsername,
  getNotificationPrefs,
  updateNotificationPrefs,
  type Profile,
  type NotificationPrefs,
} from "../api";
import { signOut } from "../session";
import { Layout } from "../components/Layout";

export function Home() {
  const [profile, setProfile] = useState<Profile | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [newUsername, setNewUsername] = useState("");
  const [savingUsername, setSavingUsername] = useState(false);
  const [usernameError, setUsernameError] = useState<string | null>(null);

  const [prefs, setPrefs] = useState<NotificationPrefs | null>(null);
  const [prefsError, setPrefsError] = useState<string | null>(null);

  function load() {
    fetchMe()
      .then(setProfile)
      .catch((err) => setError(err instanceof Error ? err.message : String(err)))
      .finally(() => setLoading(false));
    getNotificationPrefs()
      .then(setPrefs)
      .catch((err) => setPrefsError(err instanceof Error ? err.message : String(err)));
  }

  useEffect(load, []);

  function handleLogout() {
    signOut();
    setProfile(null);
  }

  async function handleSetUsername(e: React.FormEvent) {
    e.preventDefault();
    setUsernameError(null);
    setSavingUsername(true);
    try {
      const updated = await setUsername(newUsername.trim());
      setProfile(updated);
    } catch (err) {
      setUsernameError(err instanceof Error ? err.message : String(err));
    } finally {
      setSavingUsername(false);
    }
  }

  async function handleTogglePref(field: "notify_events" | "notify_reminder") {
    if (!prefs) return;
    const next = !prefs[field];
    setPrefs({ ...prefs, [field]: next });
    try {
      await updateNotificationPrefs({ [field]: next });
    } catch (err) {
      setPrefs(prefs);
      setPrefsError(err instanceof Error ? err.message : String(err));
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
        <p className="text-rose-600">Signed in, but couldn't load your profile: {error}</p>
      </div>
    );
  }

  if (!profile) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center gap-6 px-4 text-center">
        <h1 className="text-4xl font-bold text-indigo-600">Hisaab</h1>
        <p className="max-w-sm text-gray-500">Split expenses with friends and family, simply.</p>
        <div className="flex gap-3">
          <Link
            to="/login"
            className="rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-indigo-500"
          >
            Log in
          </Link>
          <Link
            to="/signup"
            className="rounded-md border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700 shadow-sm hover:bg-gray-50"
          >
            Sign up
          </Link>
        </div>
      </div>
    );
  }

  return (
    <Layout userDisplayName={profile.display_name} onLogout={handleLogout}>
      <h1 className="text-2xl font-bold text-gray-900">Welcome, {profile.display_name}</h1>

      {profile.needs_username ? (
        <form
          onSubmit={handleSetUsername}
          className="mt-4 max-w-sm rounded-lg border border-gray-200 bg-white p-4 shadow-sm"
        >
          <p className="mb-3 text-sm text-gray-600">Choose a username (this can't be changed later):</p>
          {usernameError && <p className="mb-2 text-sm text-rose-600">Error: {usernameError}</p>}
          <div className="flex gap-2">
            <input
              value={newUsername}
              onChange={(e) => setNewUsername(e.target.value)}
              placeholder="lowercase, 3-20 chars, a-z0-9_"
              minLength={3}
              maxLength={20}
              required
              className="block w-full rounded-md border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
            />
            <button
              type="submit"
              disabled={savingUsername}
              className="shrink-0 rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-indigo-500 disabled:opacity-50"
            >
              Save
            </button>
          </div>
        </form>
      ) : (
        <p className="mt-1 text-gray-500">@{profile.username}</p>
      )}

      <p className="mt-1 text-gray-500">{profile.email}</p>

      <Link
        to="/groups"
        className="mt-6 inline-block rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-indigo-500"
      >
        Go to Groups
      </Link>

      <div className="mt-8 max-w-sm rounded-lg border border-gray-200 bg-white p-4 shadow-sm">
        <h2 className="text-sm font-semibold text-gray-900">Notifications</h2>

        {prefsError && <p className="mt-2 text-sm text-rose-600">Error: {prefsError}</p>}

        {prefs ? (
          <div className="mt-3 space-y-3">
            <label className="flex items-center justify-between text-sm text-gray-700">
              Event emails (invites, expenses, settlements)
              <input
                type="checkbox"
                checked={prefs.notify_events}
                onChange={() => handleTogglePref("notify_events")}
                className="h-4 w-4 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
              />
            </label>
            <label className="flex items-center justify-between text-sm text-gray-700">
              Weekly balance reminder
              <input
                type="checkbox"
                checked={prefs.notify_reminder}
                onChange={() => handleTogglePref("notify_reminder")}
                className="h-4 w-4 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
              />
            </label>
          </div>
        ) : (
          !prefsError && <p className="mt-2 text-sm text-gray-400">Loading…</p>
        )}
      </div>
    </Layout>
  );
}
