```elixir
defmodule MyApp.Finance.BudgetTracker do
  @moduledoc """
  Tracks departmental budget consumption against allocated amounts for a
  given fiscal period. Spend figures are aggregated from the `expense_items`
  table using a single grouped query. Budget utilisation warnings are
  emitted via telemetry when consumption exceeds configurable thresholds,
  letting alert rules live outside the tracking logic.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Finance.ExpenseItem

  @warning_threshold 0.80
  @critical_threshold 0.95

  @type department_id :: String.t()
  @type fiscal_period :: %{year: pos_integer(), quarter: 1..4}

  @type budget_status :: %{
          department_id: department_id(),
          allocated_cents: non_neg_integer(),
          spent_cents: non_neg_integer(),
          remaining_cents: integer(),
          utilisation: float(),
          status: :healthy | :warning | :critical | :over_budget
        }

  @doc """
  Returns budget status for all departments in `fiscal_period`.
  Only departments with an allocated budget record are included.
  """
  @spec summary(fiscal_period()) :: [budget_status()]
  def summary(%{year: year, quarter: quarter}) do
    allocated = fetch_allocations(year, quarter)
    spent = fetch_spent(year, quarter)

    allocated
    |> Enum.map(fn {dept_id, allocated_cents} ->
      spent_cents = Map.get(spent, dept_id, 0)
      build_status(dept_id, allocated_cents, spent_cents)
    end)
    |> Enum.sort_by(& &1.utilisation, :desc)
    |> tap(&emit_telemetry/1)
  end

  @doc "Returns the budget status for a single `department_id`."
  @spec department_status(department_id(), fiscal_period()) ::
          {:ok, budget_status()} | {:error, :no_budget}
  def department_status(dept_id, period) when is_binary(dept_id) do
    case Enum.find(summary(period), &(&1.department_id == dept_id)) do
      nil -> {:error, :no_budget}
      status -> {:ok, status}
    end
  end

  @spec build_status(department_id(), non_neg_integer(), non_neg_integer()) :: budget_status()
  defp build_status(dept_id, allocated, spent) do
    remaining = allocated - spent
    utilisation = if allocated > 0, do: Float.round(spent / allocated, 4), else: 0.0

    status =
      cond do
        utilisation > 1.0 -> :over_budget
        utilisation >= @critical_threshold -> :critical
        utilisation >= @warning_threshold -> :warning
        true -> :healthy
      end

    %{
      department_id: dept_id,
      allocated_cents: allocated,
      spent_cents: spent,
      remaining_cents: remaining,
      utilisation: utilisation,
      status: status
    }
  end

  @spec fetch_allocations(pos_integer(), 1..4) :: %{department_id() => non_neg_integer()}
  defp fetch_allocations(year, quarter) do
    MyApp.Finance.BudgetAllocation
    |> where([b], b.fiscal_year == ^year and b.fiscal_quarter == ^quarter)
    |> select([b], {b.department_id, b.allocated_cents})
    |> Repo.all()
    |> Map.new()
  end

  @spec fetch_spent(pos_integer(), 1..4) :: %{department_id() => non_neg_integer()}
  defp fetch_spent(year, quarter) do
    {start_date, end_date} = quarter_date_range(year, quarter)

    ExpenseItem
    |> where([e], e.expense_date >= ^start_date and e.expense_date <= ^end_date)
    |> where([e], e.approved == true)
    |> group_by([e], e.department_id)
    |> select([e], {e.department_id, sum(e.amount_cents)})
    |> Repo.all()
    |> Map.new()
  end

  @spec quarter_date_range(pos_integer(), 1..4) :: {Date.t(), Date.t()}
  defp quarter_date_range(year, quarter) do
    start_month = (quarter - 1) * 3 + 1
    end_month = start_month + 2
    start_date = Date.new!(year, start_month, 1)
    end_date = Date.new!(year, end_month, 1) |> Date.end_of_month()
    {start_date, end_date}
  end

  @spec emit_telemetry([budget_status()]) :: :ok
  defp emit_telemetry(statuses) do
    Enum.each(statuses, fn s ->
      if s.status in [:warning, :critical, :over_budget] do
        :telemetry.execute(
          [:my_app, :budget, :threshold_exceeded],
          %{utilisation: s.utilisation},
          %{department_id: s.department_id, status: s.status}
        )
      end
    end)
  end
end
```
