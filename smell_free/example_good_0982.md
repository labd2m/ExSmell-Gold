```elixir
defmodule Finance.Ledger do
  @moduledoc """
  A pure functional double-entry ledger. Every financial event is recorded
  as a balanced `Entry` with equal debit and credit amounts across two
  accounts, maintaining the fundamental accounting equation at all times.
  The ledger is immutable; posting an entry produces a new ledger struct.
  Balances are derived from entries rather than stored separately, making
  the ledger fully auditable and replayable from any point in history.
  """

  alias Finance.Ledger.{Account, Entry}

  @type account_id :: binary()
  @type amount_cents :: integer()
  @type t :: %__MODULE__{
          entries: [Entry.t()],
          accounts: %{account_id() => Account.t()}
        }

  defstruct entries: [], accounts: %{}

  # ---------------------------------------------------------------------------
  # Account management
  # ---------------------------------------------------------------------------

  @doc "Adds a new account to the ledger. Returns `{:error, :duplicate}` when the ID exists."
  @spec open_account(t(), account_id(), Account.type()) :: {:ok, t()} | {:error, :duplicate}
  def open_account(%__MODULE__{accounts: accounts} = ledger, id, type)
      when is_binary(id) and type in [:asset, :liability, :equity, :revenue, :expense] do
    if Map.has_key?(accounts, id) do
      {:error, :duplicate}
    else
      account = %Account{id: id, type: type, name: id}
      {:ok, %{ledger | accounts: Map.put(accounts, id, account)}}
    end
  end

  # ---------------------------------------------------------------------------
  # Posting entries
  # ---------------------------------------------------------------------------

  @doc """
  Posts a balanced double-entry between `debit_account` and `credit_account`.
  The entry must balance (equal amounts on both sides). Returns `{:ok, ledger}`
  or `{:error, reason}`.
  """
  @spec post(t(), account_id(), account_id(), amount_cents(), binary()) ::
          {:ok, t()} | {:error, term()}
  def post(%__MODULE__{} = ledger, debit_id, credit_id, amount, description)
      when is_binary(debit_id) and is_binary(credit_id) and
             is_integer(amount) and amount > 0 and is_binary(description) do
    with :ok <- assert_account_exists(ledger, debit_id),
         :ok <- assert_account_exists(ledger, credit_id),
         :ok <- assert_different_accounts(debit_id, credit_id) do
      entry = %Entry{
        id: generate_entry_id(),
        debit_account_id: debit_id,
        credit_account_id: credit_id,
        amount_cents: amount,
        description: description,
        posted_at: DateTime.utc_now()
      }

      {:ok, %{ledger | entries: [entry | ledger.entries]}}
    end
  end

  # ---------------------------------------------------------------------------
  # Balance queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns the balance for `account_id` in cents. The sign convention follows
  normal account balance rules: asset and expense accounts increase with debits,
  liability/equity/revenue accounts increase with credits.
  """
  @spec balance(t(), account_id()) :: {:ok, amount_cents()} | {:error, :account_not_found}
  def balance(%__MODULE__{} = ledger, account_id) when is_binary(account_id) do
    with {:ok, account} <- fetch_account(ledger, account_id) do
      debit_total =
        ledger.entries
        |> Enum.filter(&(&1.debit_account_id == account_id))
        |> Enum.sum_by(& &1.amount_cents)

      credit_total =
        ledger.entries
        |> Enum.filter(&(&1.credit_account_id == account_id))
        |> Enum.sum_by(& &1.amount_cents)

      balance =
        case account.type do
          type when type in [:asset, :expense] -> debit_total - credit_total
          _ -> credit_total - debit_total
        end

      {:ok, balance}
    end
  end

  @doc """
  Returns a trial balance: a map of `account_id => balance_cents` for all accounts.
  The sum of all balances must be zero for a balanced ledger.
  """
  @spec trial_balance(t()) :: %{account_id() => amount_cents()}
  def trial_balance(%__MODULE__{} = ledger) do
    Map.new(ledger.accounts, fn {id, _account} ->
      {:ok, bal} = balance(ledger, id)
      {id, bal}
    end)
  end

  @doc """
  Returns `true` when the ledger is in balance (trial balance sums to zero).
  """
  @spec balanced?(t()) :: boolean()
  def balanced?(%__MODULE__{} = ledger) do
    ledger |> trial_balance() |> Map.values() |> Enum.sum() == 0
  end

  @doc """
  Returns all entries affecting `account_id` in reverse chronological order.
  """
  @spec entries_for(t(), account_id()) :: [Entry.t()]
  def entries_for(%__MODULE__{entries: entries}, account_id) when is_binary(account_id) do
    Enum.filter(entries, fn entry ->
      entry.debit_account_id == account_id or entry.credit_account_id == account_id
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_account(%{accounts: accounts}, id) do
    case Map.fetch(accounts, id) do
      {:ok, account} -> {:ok, account}
      :error -> {:error, :account_not_found}
    end
  end

  defp assert_account_exists(ledger, id) do
    case fetch_account(ledger, id) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp assert_different_accounts(a, b) when a == b, do: {:error, :same_account}
  defp assert_different_accounts(_a, _b), do: :ok

  defp generate_entry_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end

defmodule Finance.Ledger.Account do
  @moduledoc false
  defstruct [:id, :type, :name]
  @type type :: :asset | :liability | :equity | :revenue | :expense
  @type t :: %__MODULE__{id: binary(), type: type(), name: binary()}
end

defmodule Finance.Ledger.Entry do
  @moduledoc false
  defstruct [:id, :debit_account_id, :credit_account_id, :amount_cents, :description, :posted_at]
  @type t :: %__MODULE__{}
end
```
