```elixir
defmodule Finance.MultiCurrencyLedger do
  @moduledoc """
  Records financial transactions in multiple currencies within a single
  ledger account. All debit and credit legs carry their native currency;
  an exchange rate is recorded at transaction time for reporting purposes.
  The ledger reports balances in each currency independently so no implicit
  conversion occurs unless explicitly requested.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Finance.{MultiCurrencyEntry}

  @type account_id :: String.t()
  @type currency :: String.t()
  @type amount_cents :: integer()
  @type entry_side :: :debit | :credit

  @doc "Records a credit entry in `currency` for `account_id`."
  @spec credit(account_id(), amount_cents(), currency(), String.t()) ::
          {:ok, MultiCurrencyEntry.t()} | {:error, Ecto.Changeset.t()}
  def credit(account_id, amount_cents, currency, reference)
      when is_binary(account_id) and is_integer(amount_cents) and amount_cents > 0 do
    insert_entry(account_id, :credit, amount_cents, currency, reference)
  end

  @doc "Records a debit entry in `currency` for `account_id`."
  @spec debit(account_id(), amount_cents(), currency(), String.t()) ::
          {:ok, MultiCurrencyEntry.t()} | {:error, Ecto.Changeset.t()}
  def debit(account_id, amount_cents, currency, reference)
      when is_binary(account_id) and is_integer(amount_cents) and amount_cents > 0 do
    insert_entry(account_id, :debit, amount_cents, currency, reference)
  end

  @doc "Returns the balance per currency for `account_id` as a map."
  @spec balances(account_id()) :: %{currency() => amount_cents()}
  def balances(account_id) when is_binary(account_id) do
    from(e in MultiCurrencyEntry,
      where: e.account_id == ^account_id,
      group_by: [e.currency, e.side],
      select: {e.currency, e.side, sum(e.amount_cents)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {currency, side, total}, acc ->
      delta = if side == "credit", do: total, else: -total
      Map.update(acc, currency, delta, &(&1 + delta))
    end)
  end

  @doc "Returns the balance in a single `currency` for `account_id`."
  @spec balance_in(account_id(), currency()) :: amount_cents()
  def balance_in(account_id, currency) when is_binary(account_id) and is_binary(currency) do
    Map.get(balances(account_id), currency, 0)
  end

  @doc "Returns all entries for `account_id` in chronological order."
  @spec entries(account_id(), keyword()) :: [MultiCurrencyEntry.t()]
  def entries(account_id, opts \\ []) when is_binary(account_id) do
    limit = Keyword.get(opts, :limit, 100)
    currency_filter = Keyword.get(opts, :currency)

    q = from(e in MultiCurrencyEntry,
      where: e.account_id == ^account_id,
      order_by: [asc: e.inserted_at],
      limit: ^limit
    )

    q = if currency_filter, do: where(q, [e], e.currency == ^currency_filter), else: q
    Repo.all(q)
  end

  defp insert_entry(account_id, side, amount_cents, currency, reference) do
    attrs = %{
      account_id: account_id,
      side: Atom.to_string(side),
      amount_cents: amount_cents,
      currency: String.upcase(currency),
      reference: reference
    }

    %MultiCurrencyEntry{} |> MultiCurrencyEntry.changeset(attrs) |> Repo.insert()
  end
end
```
