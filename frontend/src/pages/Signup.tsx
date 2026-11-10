import { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { confirmSignUp, resendConfirmationCode, signIn, signUp } from "../cognito";
import { startSession } from "../session";

export function Signup() {
  const navigate = useNavigate();
  const [step, setStep] = useState<"register" | "confirm">("register");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [username, setUsername] = useState("");
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [resent, setResent] = useState(false);

  async function handleRegister(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      const newUsername = await signUp(email.trim(), password);
      setUsername(newUsername);
      setStep("confirm");
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSubmitting(false);
    }
  }

  async function handleConfirm(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      await confirmSignUp(username, code.trim());
      // Confirming doesn't sign you in — do that immediately after so the
      // user lands straight on Home instead of a second login step.
      // Sign-in uses the email alias, not the internal username — that
      // direction works fine since email is verified by this point.
      const result = await signIn(email.trim(), password);
      startSession(result);
      navigate("/");
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSubmitting(false);
    }
  }

  async function handleResend() {
    setError(null);
    setResent(false);
    try {
      await resendConfirmationCode(username);
      setResent(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-6 px-4">
      <h1 className="text-3xl font-bold text-indigo-600">Hisaab</h1>

      {step === "register" ? (
        <form
          onSubmit={handleRegister}
          className="w-full max-w-sm rounded-lg border border-gray-200 bg-white p-6 shadow-sm"
        >
          <h2 className="mb-4 text-lg font-semibold text-gray-900">Sign up</h2>
          {error && <p className="mb-3 text-sm text-rose-600">{error}</p>}
          <label className="mb-3 block text-sm">
            <span className="mb-1 block text-gray-600">Email</span>
            <input
              type="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="block w-full rounded-md border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
            />
          </label>
          <label className="mb-4 block text-sm">
            <span className="mb-1 block text-gray-600">Password</span>
            <input
              type="password"
              required
              minLength={8}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="block w-full rounded-md border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
            />
            <span className="mt-1 block text-xs text-gray-400">
              8+ characters, with an uppercase letter, lowercase letter, and number.
            </span>
          </label>
          <button
            type="submit"
            disabled={submitting}
            className="w-full rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-indigo-500 disabled:opacity-50"
          >
            {submitting ? "Signing up…" : "Sign up"}
          </button>
          <p className="mt-4 text-center text-sm text-gray-500">
            Already have an account?{" "}
            <Link to="/login" className="font-medium text-indigo-600 hover:text-indigo-500">
              Log in
            </Link>
          </p>
        </form>
      ) : (
        <form
          onSubmit={handleConfirm}
          className="w-full max-w-sm rounded-lg border border-gray-200 bg-white p-6 shadow-sm"
        >
          <h2 className="mb-4 text-lg font-semibold text-gray-900">Confirm your email</h2>
          <p className="mb-3 text-sm text-gray-600">
            We sent a confirmation code to {email}. Enter it below.
          </p>
          {error && <p className="mb-3 text-sm text-rose-600">{error}</p>}
          {resent && <p className="mb-3 text-sm text-emerald-600">Code resent.</p>}
          <label className="mb-4 block text-sm">
            <span className="mb-1 block text-gray-600">Confirmation code</span>
            <input
              type="text"
              required
              value={code}
              onChange={(e) => setCode(e.target.value)}
              className="block w-full rounded-md border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
            />
          </label>
          <button
            type="submit"
            disabled={submitting}
            className="w-full rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-indigo-500 disabled:opacity-50"
          >
            {submitting ? "Confirming…" : "Confirm"}
          </button>
          <button
            type="button"
            onClick={handleResend}
            className="mt-3 w-full text-center text-sm text-gray-500 hover:text-gray-700"
          >
            Resend code
          </button>
        </form>
      )}
    </div>
  );
}
