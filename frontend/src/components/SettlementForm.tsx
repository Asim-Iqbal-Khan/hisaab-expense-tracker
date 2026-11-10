import { useState } from "react";
import { paisaToRupees, recordSettlement, rupeesToPaisa, type GroupMember } from "../api";

interface Prefill {
  counterpartyUserId: string;
  counterpartyLabel: string;
  direction: "i_paid" | "i_received";
  amountPaisa?: number;
}

interface SettlementFormProps {
  groupId: string;
  activeMembers: GroupMember[];
  currentUserId: string | undefined;
  prefill?: Prefill;
  onSaved: () => void;
  onCancel: () => void;
}

export function SettlementForm({
  groupId,
  activeMembers,
  currentUserId,
  prefill,
  onSaved,
  onCancel,
}: SettlementFormProps) {
  const otherMembers = activeMembers.filter((m) => m.id !== currentUserId);

  const [counterpartyUserId, setCounterpartyUserId] = useState(
    prefill?.counterpartyUserId ?? otherMembers[0]?.id ?? "",
  );
  const [direction, setDirection] = useState<"i_paid" | "i_received">(prefill?.direction ?? "i_paid");
  const [amountRupees, setAmountRupees] = useState(
    prefill?.amountPaisa !== undefined ? String(paisaToRupees(String(prefill.amountPaisa))) : "",
  );
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);

    const amountPaisa = rupeesToPaisa(Number(amountRupees));
    if (!Number.isFinite(amountPaisa) || amountPaisa <= 0) {
      setError("Enter a valid amount greater than zero");
      return;
    }
    if (!counterpartyUserId) {
      setError("Select who this settlement is with");
      return;
    }

    setSaving(true);
    try {
      await recordSettlement(groupId, {
        counterpartyUserId,
        direction,
        amountPaisa,
        note: note.trim() || undefined,
      });
      onSaved();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <h3 className="text-lg font-semibold text-gray-900">Record a settlement</h3>
      {error && <p className="text-sm text-rose-600">Error: {error}</p>}

      {prefill ? (
        <p className="text-sm text-gray-700">
          With: <span className="font-medium">{prefill.counterpartyLabel}</span>
        </p>
      ) : (
        <label className="flex flex-col gap-1 text-sm font-medium text-gray-700">
          With
          <select
            value={counterpartyUserId}
            onChange={(e) => setCounterpartyUserId(e.target.value)}
            className="rounded-md border border-gray-300 px-3 py-2 text-sm font-normal shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
          >
            {otherMembers.map((m) => (
              <option key={m.id} value={m.id}>
                {m.display_name} (@{m.username})
              </option>
            ))}
          </select>
        </label>
      )}

      <div className="flex gap-4 text-sm text-gray-700">
        <label className="flex items-center gap-2">
          <input
            type="radio"
            checked={direction === "i_paid"}
            onChange={() => setDirection("i_paid")}
            className="text-indigo-600 focus:ring-indigo-500"
          />
          I paid them
        </label>
        <label className="flex items-center gap-2">
          <input
            type="radio"
            checked={direction === "i_received"}
            onChange={() => setDirection("i_received")}
            className="text-indigo-600 focus:ring-indigo-500"
          />
          I received from them
        </label>
      </div>

      <label className="flex flex-col gap-1 text-sm font-medium text-gray-700">
        Amount (rupees)
        <input
          type="number"
          step="0.01"
          min="0.01"
          value={amountRupees}
          onChange={(e) => setAmountRupees(e.target.value)}
          required
          className="rounded-md border border-gray-300 px-3 py-2 text-sm font-normal shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
        />
      </label>

      <label className="flex flex-col gap-1 text-sm font-medium text-gray-700">
        Note (optional)
        <input
          value={note}
          onChange={(e) => setNote(e.target.value)}
          maxLength={140}
          className="rounded-md border border-gray-300 px-3 py-2 text-sm font-normal shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
        />
      </label>

      <div className="flex gap-2 pt-2">
        <button
          type="submit"
          disabled={saving}
          className="rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-indigo-500 disabled:opacity-50"
        >
          Record
        </button>
        <button
          type="button"
          onClick={onCancel}
          disabled={saving}
          className="rounded-md border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700 shadow-sm hover:bg-gray-50 disabled:opacity-50"
        >
          Cancel
        </button>
      </div>
    </form>
  );
}
