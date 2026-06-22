```elixir
defmodule Finance.BudgetContext do
  @moduledoc """
  Manages budget definitions and expenditure tracking. Each budget covers
  a named category within a fiscal period. Expenditures are validated
  against the remaining budget before being recorded. The context exposes
  utilisation percentages and over-budget detection without requiring
  callers to understand the underlying schema.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Finance.{Budget, Expenditure}

  @type budget_id :: Ecto.UUID.t()
  @type period :: %{year: pos_integer(), month: 1..12}

  @doc "Creates a budget for the given category and period."
  @spec create(String.t(), pos_integer(), String.t(), period()) ::
          {:ok, Budget.t()} | {:error, Ecto.Changeset.t()}
  def create(category, amount_cents, currency, %{year: year, month: month}) do
    attrs = %{
      category: category,
      amount_cents: amount_cents,
      currency: currency,
      year: year,
      month: month
    }

    %Budget{} |> Budget.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Records an expenditure against a budget. Returns
  `{:error, :budget_exceeded}` when the expenditure would exceed the
  remaining allowance.
  """
  @spec record_expenditure(budget_id(), pos_integer(), String.t()) ::
          {:ok, Expenditure.t()} | {:error, :budget_not_found | :budget_exceeded | Ecto.Changeset.t()}
  def record_expenditure(budget_id, amount_cents, description)
      when is_binary(budget_id) and is_integer(amount_cents) and amount_cents > 0 do
    Repo.transaction(fn ->
      case Repo.get(Budget, budget_id) do
        nil ->
          Repo.rollback(:budget_not_found)

        budget ->
          spent = total_spent(budget_id)
          remaining = budget.amount_cents - spent

          if amount_cents > remaining do
            Repo.rollback(:budget_exceeded)
          else
            attrs = %{budget_id: budget_id, amount_cents: amount_cents, description: description}

            case %Expenditure{} |> Expenditure.changeset(attrs) |> Repo.insert() do
              {:ok, exp} -> exp
              {:error, cs} -> Repo.rollback(cs)
            end
          end
      end
    end)
  end

  @doc "Returns the utilisation percentage (0.0–100.0) for `budget_id`."
  @spec utilisation(budget_id()) :: {:ok, float()} | {:error, :not_found}
  def utilisation(budget_id) when is_binary(budget_id) do
    case Repo.get(Budget, budget_id) do
      nil ->
        {:error, :not_found}

      budget ->
        spent = total_spent(budget_id)
        pct = if budget.amount_cents > 0, do: spent / budget.amount_cents * 100, else: 0.0
        {:ok, Float.round(pct, 2)}
    end
  end

  @doc "Returns all budgets for the given period sorted by category."
  @spec list_for_period(period()) :: [Budget.t()]
  def list_for_period(%{year: year, month: month}) do
    from(b in Budget,
      where: b.year == ^year and b.month == ^month,
      order_by: [asc: b.category]
    )
    |> Repo.all()
  end

  @doc "Returns all expenditures for `budget_id` in chronological order."
  @spec expenditures(budget_id()) :: [Expenditure.t()]
  def expenditures(budget_id) when is_binary(budget_id) do
    from(e in Expenditure,
      where: e.budget_id == ^budget_id,
      order_by: [asc: e.inserted_at]
    )
    |> Repo.all()
  end

  defp total_spent(budget_id) do
    from(e in Expenditure,
      where: e.budget_id == ^budget_id,
      select: sum(e.amount_cents)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end
end
```
