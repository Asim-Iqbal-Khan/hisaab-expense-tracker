import { useState } from "react";
import {
  createExpense,
  paisaToRupees,
  rupeesToPaisa,
  updateExpense,
  type Expense,
  type GroupMember,
} from "../api";

interface Candidate {
  id: string;
  label: string;
}

// The candidate list for split/payer selection must include anyone who was
// already the payer or in the split before this edit, not just currently
// active members — group_members rows are never hard-deleted (leaving just
// sets left_at), so a departed member can still be legitimately part of an
// existing expense. Omitting them here would let an unrelated edit (e.g.
// fixing a typo) silently drop their share when the form resubmits whatever
// is currently checked.
function buildCandidates(activeMembers: GroupMember[], existingExpense: Expense | null): Candidate[] {
  const map = new Map<string, Candidate>();
  for (const m of activeMembers) {
    map.set(m.id, { id: m.id, label: `${m.display_name} (@${m.username})` });
  }
  if (existingExpense) {
    const extras = [
      {
        id: existingExpense.paid_by,
        username: existingExpense.paid_by_username,
        display_name: existingExpense.paid_by_display_name,
      },
      ...existingExpense.splits.map((s) => ({
        id: s.user_id,
        username: s.username,
        display_name: s.display_name,
      })),
    ];
    for (const extra of extras) {
      if (!map.has(extra.id)) {
        map.set(extra.id, { id: extra.id, label: `${extra.display_name} (@${extra.username}) — left group` });
      }
    }
  }
  return [...map.values()];
}

interface ExpenseFormProps {
  groupId: string;
  activeMembers: GroupMember[];
  existingExpense: Expense | null;
  onSaved: () => void;
  onCancel: () => void;
}

export function ExpenseForm({
  groupId,
  activeMembers,
  existingExpense,
  onSaved,
  onCancel,
}: ExpenseFormProps) {
  const candidates = buildCandidates(activeMembers, existingExpense);
  const today = new Date().toISOString().slice(0, 10);

  const [description, setDescription] = useState(existingExpense?.description ?? "");
  const [amountRupees, setAmountRupees] = useState(
    existingExpense ? String(paisaToRupees(existingExpense.amount_paisa)) : "",
  );
  const [expenseDate, setExpenseDate] = useState(existingExpense?.expense_date ?? today);
  const [paidBy, setPaidBy] = useState(existingExpense?.paid_by ?? activeMembers[0]?.id ?? "");
  const [selectedSplitIds, setSelectedSplitIds] = useState<Set<string>>(
    new Set(existingExpense ? existingExpense.splits.map((s) => s.user_id) : activeMembers.map((m) => m.id)),
  );
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function toggleSplit(id: string) {
    setSelectedSplitIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) {
        next.delete(id);
      } else {
        next.add(id);
      }
      return next;
    });
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);

    const amountPaisa = rupeesToPaisa(Number(amountRupees));
    if (!Number.isFinite(amountPaisa) || amountPaisa <= 0) {
      setError("Enter a valid amount greater than zero");
      return;
    }
    if (selectedSplitIds.size === 0) {
      setError("Select at least one member to split with");
      return;
    }

    setSaving(true);
    try {
      const input = {
        description: description.trim(),
        amountPaisa,
        expenseDate,
        paidBy,
        splitUserIds: [...selectedSplitIds],
      };
      if (existingExpense) {
        await updateExpense(groupId, existingExpense.id, input);
      } else {
        await createExpense(groupId, input);
      }
      onSaved();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <h3 className="text-lg font-semibold text-gray-900">
        {existingExpense ? "Edit expense" : "Add expense"}
      </h3>
      {error && <p className="text-sm text-rose-600">Error: {error}</p>}

      <label className="flex flex-col gap-1 text-sm font-medium text-gray-700">
        Description
        <input
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          maxLength={140}
          required
          className="rounded-md border border-gray-300 px-3 py-2 text-sm font-normal shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
        />
      </label>

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
        Date
        <input
          type="date"
          value={expenseDate}
          max={today}
          onChange={(e) => setExpenseDate(e.target.value)}
          required
          className="rounded-md border border-gray-300 px-3 py-2 text-sm font-normal shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
        />
      </label>

      <label className="flex flex-col gap-1 text-sm font-medium text-gray-700">
        Paid by
        <select
          value={paidBy}
          onChange={(e) => setPaidBy(e.target.value)}
          required
          className="rounded-md border border-gray-300 px-3 py-2 text-sm font-normal shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
        >
          {candidates.map((c) => (
            <option key={c.id} value={c.id}>
              {c.label}
            </option>
          ))}
        </select>
      </label>

      <div>
        <p className="mb-1 text-sm font-medium text-gray-700">Split between</p>
        <div className="flex flex-col gap-1">
          {candidates.map((c) => (
            <label key={c.id} className="flex items-center gap-2 text-sm text-gray-700">
              <input
                type="checkbox"
                checked={selectedSplitIds.has(c.id)}
                onChange={() => toggleSplit(c.id)}
                className="rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
              />
              {c.label}
            </label>
          ))}
        </div>
      </div>

      <div className="flex gap-2 pt-2">
        <button
          type="submit"
          disabled={saving}
          className="rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-indigo-500 disabled:opacity-50"
        >
          {existingExpense ? "Save changes" : "Add expense"}
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
