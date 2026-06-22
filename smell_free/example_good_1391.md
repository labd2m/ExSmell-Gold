```elixir
defmodule Retail.Loyalty.PointsLedger do
  @moduledoc """
  Manages a customer loyalty points ledger with earn, redeem, and expiry operations.
  All balance mutations are append-only; the current balance is derived from the ledger.
  Points expire after a configurable TTL and are excluded from balance calculations.
  """

  alias Retail.Loyalty.LedgerEntry

  @type t :: %__MODULE__{
          customer_id: String.t(),
          entries: [LedgerEntry.t()]
        }

  defstruct [:customer_id, entries: []]

  @doc """
  Creates a new empty points ledger for `customer_id`.
  """
  @spec new(String.t()) :: {:ok, t()} | {:error, String.t()}
  def new(customer_id) when is_binary(customer_id) and customer_id != "" do
    {:ok, %__MODULE__{customer_id: customer_id, entries: []}}
  end

  def new(_), do: {:error, "customer_id must be a non-empty string"}

  @doc """
  Records an earn event for `points` with an optional expiry date.
  """
  @spec earn(t(), pos_integer(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def earn(%__MODULE__{} = ledger, points, opts \\ [])
      when is_integer(points) and points > 0 do
    expires_on = Keyword.get(opts, :expires_on)
    reference = Keyword.get(opts, :reference, "")

    with :ok <- validate_expiry(expires_on) do
      entry = LedgerEntry.new(:earn, points, expires_on, reference)
      {:ok, %{ledger | entries: ledger.entries ++ [entry]}}
    end
  end

  def earn(%__MODULE__{}, _points, _opts), do: {:error, "points must be a positive integer"}

  @doc """
  Redeems `points` from the ledger if sufficient unexpired balance is available.
  """
  @spec redeem(t(), pos_integer(), String.t()) :: {:ok, t()} | {:error, :insufficient_balance | String.t()}
  def redeem(%__MODULE__{} = ledger, points, reference \\ "")
      when is_integer(points) and points > 0 do
    current = balance(ledger)

    if current >= points do
      entry = LedgerEntry.new(:redeem, -points, nil, reference)
      {:ok, %{ledger | entries: ledger.entries ++ [entry]}}
    else
      {:error, :insufficient_balance}
    end
  end

  def redeem(%__MODULE__{}, _points, _ref), do: {:error, "points must be a positive integer"}

  @doc """
  Returns the current valid (non-expired) point balance.
  """
  @spec balance(t()) :: non_neg_integer()
  def balance(%__MODULE__{entries: entries}) do
    today = Date.utc_today()

    entries
    |> Enum.reject(fn e -> entry_expired?(e, today) end)
    |> Enum.reduce(0, fn e, acc -> acc + e.points end)
    |> max(0)
  end

  @doc """
  Returns all entries within a date range, inclusive.
  """
  @spec entries_between(t(), Date.t(), Date.t()) :: [LedgerEntry.t()]
  def entries_between(%__MODULE__{entries: entries}, from_date, to_date) do
    Enum.filter(entries, fn e ->
      entry_date = DateTime.to_date(e.recorded_at)
      Date.compare(entry_date, from_date) != :lt and
        Date.compare(entry_date, to_date) != :gt
    end)
  end

  defp entry_expired?(%LedgerEntry{expires_on: nil}, _today), do: false
  defp entry_expired?(%LedgerEntry{expires_on: exp, type: :earn}, today), do: Date.compare(exp, today) == :lt
  defp entry_expired?(_entry, _today), do: false

  defp validate_expiry(nil), do: :ok
  defp validate_expiry(%Date{} = d) do
    if Date.compare(d, Date.utc_today()) == :gt, do: :ok, else: {:error, "expires_on must be a future date"}
  end
  defp validate_expiry(_), do: {:error, "expires_on must be a Date or nil"}
end

defmodule Retail.Loyalty.LedgerEntry do
  @moduledoc """
  An immutable loyalty points ledger entry.
  """

  @type entry_type :: :earn | :redeem | :adjustment | :expiry
  @type t :: %__MODULE__{
          type: entry_type(),
          points: integer(),
          expires_on: Date.t() | nil,
          reference: String.t(),
          recorded_at: DateTime.t()
        }

  defstruct [:type, :points, :expires_on, :reference, :recorded_at]

  @spec new(entry_type(), integer(), Date.t() | nil, String.t()) :: t()
  def new(type, points, expires_on, reference) do
    %__MODULE__{
      type: type,
      points: points,
      expires_on: expires_on,
      reference: reference,
      recorded_at: DateTime.utc_now()
    }
  end
end
```
