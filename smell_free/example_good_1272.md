```elixir
defmodule Loyalty.PointsLedger do
  @moduledoc """
  Context for managing customer loyalty point balances through an immutable ledger.

  All balance changes are recorded as ledger entries rather than mutating a
  running total. The current balance is derived by summing confirmed entries.
  """

  import Ecto.Query

  alias Loyalty.Repo
  alias Loyalty.PointsLedger.{Entry, BalanceSummary}

  @type result(t) :: {:ok, t} | {:error, Ecto.Changeset.t() | String.t()}

  @doc """
  Credits points to a customer's ledger for the given reason.
  """
  @spec credit(String.t(), pos_integer(), String.t(), map()) :: result(Entry.t())
  def credit(customer_id, points, reason, metadata \\ %{})
      when is_binary(customer_id) and is_integer(points) and points > 0 and is_binary(reason) do
    insert_entry(customer_id, :credit, points, reason, metadata)
  end

  @doc """
  Debits points from a customer's ledger if sufficient balance exists.
  """
  @spec debit(String.t(), pos_integer(), String.t(), map()) :: result(Entry.t())
  def debit(customer_id, points, reason, metadata \\ %{})
      when is_binary(customer_id) and is_integer(points) and points > 0 and is_binary(reason) do
    with {:ok, summary} <- balance(customer_id),
         :ok <- assert_sufficient_balance(summary, points) do
      insert_entry(customer_id, :debit, points, reason, metadata)
    end
  end

  @doc """
  Returns the current balance summary for a customer.
  """
  @spec balance(String.t()) :: {:ok, BalanceSummary.t()} | {:error, String.t()}
  def balance(customer_id) when is_binary(customer_id) do
    credits =
      Entry
      |> where([e], e.customer_id == ^customer_id and e.kind == :credit)
      |> select([e], sum(e.points))
      |> Repo.one()
      |> then(&(&1 || 0))

    debits =
      Entry
      |> where([e], e.customer_id == ^customer_id and e.kind == :debit)
      |> select([e], sum(e.points))
      |> Repo.one()
      |> then(&(&1 || 0))

    {:ok, BalanceSummary.new(customer_id, credits, debits)}
  end

  @doc """
  Returns paginated ledger entries for a customer ordered by insertion time descending.
  """
  @spec history(String.t(), keyword()) :: [Entry.t()]
  def history(customer_id, opts \\ []) when is_binary(customer_id) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)

    Entry
    |> where([e], e.customer_id == ^customer_id)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> Repo.all()
  end

  @doc """
  Voids a previously recorded entry by inserting an offsetting reversal entry.
  """
  @spec void_entry(Entry.t(), String.t()) :: result(Entry.t())
  def void_entry(%Entry{kind: :credit} = entry, reason) when is_binary(reason) do
    insert_entry(entry.customer_id, :debit, entry.points, reason,
      %{voided_entry_id: entry.id})
  end

  def void_entry(%Entry{kind: :debit} = entry, reason) when is_binary(reason) do
    insert_entry(entry.customer_id, :credit, entry.points, reason,
      %{voided_entry_id: entry.id})
  end

  # --- private helpers ---

  defp insert_entry(customer_id, kind, points, reason, metadata) do
    %Entry{}
    |> Entry.changeset(%{
      customer_id: customer_id,
      kind: kind,
      points: points,
      reason: reason,
      metadata: metadata
    })
    |> Repo.insert()
  end

  defp assert_sufficient_balance(%BalanceSummary{available: avail}, points) when avail >= points,
    do: :ok

  defp assert_sufficient_balance(%BalanceSummary{available: avail}, points),
    do: {:error, "insufficient balance: #{avail} available, #{points} requested"}
end

defmodule Loyalty.PointsLedger.BalanceSummary do
  @moduledoc "Value object representing a customer's computed point balance."

  @enforce_keys [:customer_id, :total_credited, :total_debited, :available]
  defstruct [:customer_id, :total_credited, :total_debited, :available]

  @type t :: %__MODULE__{
          customer_id: String.t(),
          total_credited: non_neg_integer(),
          total_debited: non_neg_integer(),
          available: non_neg_integer()
        }

  @spec new(String.t(), non_neg_integer(), non_neg_integer()) :: t()
  def new(customer_id, credited, debited) do
    %__MODULE__{
      customer_id: customer_id,
      total_credited: credited,
      total_debited: debited,
      available: max(credited - debited, 0)
    }
  end
end
```
