```elixir
defmodule Ledger.Account do
  @moduledoc """
  Event-sourced aggregate managing a ledger account's balance and transaction history.
  State is reconstructed by replaying domain events. Snapshots can be applied
  to fast-forward reconstruction from a known checkpoint.
  """

  alias Ledger.Account.{Event, Snapshot}

  @type currency :: String.t()
  @type t :: %__MODULE__{
          account_id: String.t(),
          owner_id: String.t(),
          currency: currency(),
          balance_cents: integer(),
          version: non_neg_integer(),
          status: :active | :frozen | :closed
        }

  defstruct [
    :account_id,
    :owner_id,
    :currency,
    balance_cents: 0,
    version: 0,
    status: :active
  ]

  @spec open(String.t(), String.t(), currency()) ::
          {:ok, t(), Event.t()} | {:error, String.t()}
  def open(account_id, owner_id, currency)
      when is_binary(account_id) and is_binary(owner_id) and is_binary(currency) do
    if valid_currency?(currency) do
      event = Event.new(:account_opened, %{account_id: account_id, owner_id: owner_id, currency: currency})
      state = apply_event(%__MODULE__{}, event)
      {:ok, state, event}
    else
      {:error, "unsupported currency: #{currency}"}
    end
  end

  @spec credit(t(), pos_integer(), String.t()) ::
          {:ok, t(), Event.t()} | {:error, String.t()}
  def credit(%__MODULE__{status: :active} = account, amount_cents, description)
      when is_integer(amount_cents) and amount_cents > 0 and is_binary(description) do
    event = Event.new(:credited, %{amount_cents: amount_cents, description: description})
    {:ok, apply_event(account, event), event}
  end

  def credit(%__MODULE__{status: status}, _amount, _desc) do
    {:error, "cannot credit a #{status} account"}
  end

  @spec debit(t(), pos_integer(), String.t()) ::
          {:ok, t(), Event.t()} | {:error, String.t()}
  def debit(%__MODULE__{status: :active} = account, amount_cents, description)
      when is_integer(amount_cents) and amount_cents > 0 and is_binary(description) do
    if account.balance_cents >= amount_cents do
      event = Event.new(:debited, %{amount_cents: amount_cents, description: description})
      {:ok, apply_event(account, event), event}
    else
      {:error, "insufficient balance"}
    end
  end

  def debit(%__MODULE__{status: status}, _amount, _desc) do
    {:error, "cannot debit a #{status} account"}
  end

  @spec freeze(t(), String.t()) :: {:ok, t(), Event.t()} | {:error, String.t()}
  def freeze(%__MODULE__{status: :active} = account, reason) when is_binary(reason) do
    event = Event.new(:account_frozen, %{reason: reason})
    {:ok, apply_event(account, event), event}
  end

  def freeze(%__MODULE__{status: status}, _reason) do
    {:error, "cannot freeze a #{status} account"}
  end

  @spec reconstruct([Event.t()]) :: t()
  def reconstruct(events) when is_list(events) do
    Enum.reduce(events, %__MODULE__{}, &apply_event(&2, &1))
  end

  @spec reconstruct_from_snapshot(Snapshot.t(), [Event.t()]) :: t()
  def reconstruct_from_snapshot(%Snapshot{} = snapshot, events) when is_list(events) do
    base = Snapshot.to_account(snapshot)
    Enum.reduce(events, base, &apply_event(&2, &1))
  end

  @spec apply_event(t(), Event.t()) :: t()
  defp apply_event(state, %Event{type: :account_opened, data: data}) do
    %__MODULE__{
      state
      | account_id: data.account_id,
        owner_id: data.owner_id,
        currency: data.currency,
        status: :active,
        version: state.version + 1
    }
  end

  defp apply_event(state, %Event{type: :credited, data: data}) do
    %{state | balance_cents: state.balance_cents + data.amount_cents, version: state.version + 1}
  end

  defp apply_event(state, %Event{type: :debited, data: data}) do
    %{state | balance_cents: state.balance_cents - data.amount_cents, version: state.version + 1}
  end

  defp apply_event(state, %Event{type: :account_frozen}) do
    %{state | status: :frozen, version: state.version + 1}
  end

  @spec valid_currency?(String.t()) :: boolean()
  defp valid_currency?(code), do: code in ~w(USD EUR GBP JPY BRL)
end

defmodule Ledger.Account.Event do
  @moduledoc "Domain event emitted by the Ledger.Account aggregate."

  @type event_type :: :account_opened | :credited | :debited | :account_frozen

  @type t :: %__MODULE__{
          id: String.t(),
          type: event_type(),
          data: map(),
          occurred_at: DateTime.t()
        }

  @enforce_keys [:id, :type, :data, :occurred_at]
  defstruct [:id, :type, :data, :occurred_at]

  @spec new(event_type(), map()) :: t()
  def new(type, data) when is_atom(type) and is_map(data) do
    %__MODULE__{
      id: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower),
      type: type,
      data: data,
      occurred_at: DateTime.utc_now()
    }
  end
end

defmodule Ledger.Account.Snapshot do
  @moduledoc "Point-in-time snapshot of a Ledger.Account for fast state reconstruction."

  @type t :: %__MODULE__{
          account_id: String.t(),
          owner_id: String.t(),
          currency: String.t(),
          balance_cents: integer(),
          version: non_neg_integer(),
          status: atom(),
          taken_at: DateTime.t()
        }

  defstruct [:account_id, :owner_id, :currency, :balance_cents, :version, :status, :taken_at]

  @spec from_account(Ledger.Account.t()) :: t()
  def from_account(%Ledger.Account{} = acc) do
    %__MODULE__{
      account_id: acc.account_id,
      owner_id: acc.owner_id,
      currency: acc.currency,
      balance_cents: acc.balance_cents,
      version: acc.version,
      status: acc.status,
      taken_at: DateTime.utc_now()
    }
  end

  @spec to_account(t()) :: Ledger.Account.t()
  def to_account(%__MODULE__{} = snap) do
    %Ledger.Account{
      account_id: snap.account_id,
      owner_id: snap.owner_id,
      currency: snap.currency,
      balance_cents: snap.balance_cents,
      version: snap.version,
      status: snap.status
    }
  end
end
```
