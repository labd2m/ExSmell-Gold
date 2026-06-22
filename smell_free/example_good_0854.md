```elixir
defmodule Finance.RecurringExpenseTracker do
  @moduledoc """
  Tracks recurring expenses and projects future cash-flow obligations.
  Each expense carries a name, amount, currency, and recurrence rule.
  The projection engine generates scheduled occurrences over a date
  range without persisting them, keeping the module free of side effects.
  """

  @type recurrence :: :daily | :weekly | :monthly | :quarterly | :annual
  @type expense :: %{
          id: String.t(),
          name: String.t(),
          amount_cents: pos_integer(),
          currency: String.t(),
          recurrence: recurrence(),
          starts_on: Date.t(),
          ends_on: Date.t() | nil
        }

  @type occurrence :: %{
          expense_id: String.t(),
          name: String.t(),
          amount_cents: pos_integer(),
          currency: String.t(),
          due_on: Date.t()
        }

  @doc """
  Returns all scheduled occurrences for `expenses` within `[from_date, to_date]`
  in ascending due-date order.
  """
  @spec project([expense()], Date.t(), Date.t()) :: [occurrence()]
  def project(expenses, from_date, to_date)
      when is_list(expenses) and is_struct(from_date, Date) and is_struct(to_date, Date) do
    expenses
    |> Enum.flat_map(&occurrences_for(&1, from_date, to_date))
    |> Enum.sort_by(& &1.due_on, Date)
  end

  @doc "Returns the total projected spend in cents for a given currency within the range."
  @spec projected_spend([expense()], String.t(), Date.t(), Date.t()) :: non_neg_integer()
  def projected_spend(expenses, currency, from_date, to_date) when is_binary(currency) do
    expenses
    |> project(from_date, to_date)
    |> Enum.filter(fn o -> o.currency == currency end)
    |> Enum.sum_by(& &1.amount_cents)
  end

  @doc "Returns the next occurrence date for `expense` after `reference_date`."
  @spec next_occurrence(expense(), Date.t()) :: Date.t() | nil
  def next_occurrence(%{starts_on: starts, recurrence: rec, ends_on: ends_on} = _expense, reference_date) do
    candidate = advance_to_or_after(starts, reference_date, rec)

    cond do
      Date.compare(candidate, reference_date) == :lt -> nil
      not is_nil(ends_on) and Date.compare(candidate, ends_on) == :gt -> nil
      true -> candidate
    end
  end

  defp occurrences_for(%{starts_on: starts, recurrence: rec, ends_on: ends_on} = expense, from, to) do
    first = advance_to_or_after(starts, from, rec)

    stream_occurrences(first, rec)
    |> Stream.take_while(fn date ->
      Date.compare(date, to) != :gt and
        (is_nil(ends_on) or Date.compare(date, ends_on) != :gt)
    end)
    |> Enum.map(fn due_on ->
      %{expense_id: expense.id, name: expense.name, amount_cents: expense.amount_cents,
        currency: expense.currency, due_on: due_on}
    end)
  end

  defp stream_occurrences(start_date, recurrence) do
    Stream.iterate(start_date, &advance_by_one(&1, recurrence))
  end

  defp advance_to_or_after(starts, target, recurrence) do
    if Date.compare(starts, target) != :lt do
      starts
    else
      Stream.iterate(starts, &advance_by_one(&1, recurrence))
      |> Enum.find(&(Date.compare(&1, target) != :lt))
    end
  end

  defp advance_by_one(date, :daily), do: Date.add(date, 1)
  defp advance_by_one(date, :weekly), do: Date.add(date, 7)
  defp advance_by_one(date, :monthly), do: shift_months(date, 1)
  defp advance_by_one(date, :quarterly), do: shift_months(date, 3)
  defp advance_by_one(date, :annual), do: shift_months(date, 12)

  defp shift_months(%Date{year: y, month: m, day: d}, months) do
    total = y * 12 + m - 1 + months
    new_year = div(total, 12)
    new_month = rem(total, 12) + 1
    max_day = Date.days_in_month(%Date{year: new_year, month: new_month, day: 1})
    Date.new!(new_year, new_month, min(d, max_day))
  end
end
```
