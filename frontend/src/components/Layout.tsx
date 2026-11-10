import type { ReactNode } from "react";
import { Link } from "react-router-dom";

interface LayoutProps {
  children: ReactNode;
  userDisplayName?: string;
  onLogout?: () => void;
}

export function Layout({ children, userDisplayName, onLogout }: LayoutProps) {
  return (
    <div className="min-h-screen bg-gray-50">
      <nav className="border-b border-gray-200 bg-white">
        <div className="mx-auto flex max-w-4xl items-center justify-between px-4 py-3">
          <Link to="/" className="text-lg font-semibold text-indigo-600">
            Hisaab
          </Link>
          <div className="flex items-center gap-4 text-sm">
            <Link to="/groups" className="font-medium text-gray-600 hover:text-gray-900">
              Groups
            </Link>
            {userDisplayName && <span className="text-gray-500">{userDisplayName}</span>}
            {onLogout && (
              <button
                onClick={onLogout}
                className="rounded-md border border-gray-300 px-3 py-1.5 font-medium text-gray-700 hover:bg-gray-50"
              >
                Log out
              </button>
            )}
          </div>
        </div>
      </nav>
      <main className="mx-auto max-w-4xl px-4 py-8">{children}</main>
    </div>
  );
}
