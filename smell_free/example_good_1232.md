```elixir
defmodule Banking.Account do
  @moduledoc """
  Pure functional aggregate for a bank account.
  All state transitions are applied by replaying ordered domain events
  without side effects, making the logic fully testable in isolation.
  """

  @enforce_keys [:id, :owner_id, :balance_cents, :status]
  defstruct [:id, :owner_id, :balance_cents, :status, :opened_at, :closed_at]

  @type t :: %__MODULE__{
          id: String.t(),
          owner_id: String.t(),
          balance_cents: integer(),
          status: :open | :frozen | :closed,
          opened_at: DateTime.t() | nil,
          closed_at: DateTime.t() | nil
        }

  @type event ::
          {:deposited, %{amount_cents: pos_integer()}}
          | {:withdrawn, %{amount_cents: pos_integer()}}
          | {:frozen, %{reason: String.t()}}
          | {:closed, %{}}

  @spec open(String.t(), String.t(), non_neg_integer()) :: t()
  def open(id, owner_id, initial_cents \\ 0)
      when is_binary(id) and is_binary(owner_id) and is_integer(initial_cents) and
             initial_cents >= 0 do
    %__MODULE__{
      id: id,
      owner_id: owner_id,
      balance_cents: initial_cents,
      status: :open,
      opened_at: DateTime.utc_now()
    }
  end

  @spec apply_event(t(), event()) :: {:ok, t()} | {:error, atom()}
  def apply_event(%__MODULE__{status: :open} = account, {:deposited, %{amount_cents: amount}})
      when is_integer(amount) and amount > 0 do
    {:ok, %{account | balance_cents: account.balance_cents + amount}}
  end

  def apply_event(%__MODULE__{status: :open} = account, {:withdrawn, %{amount_cents: amount}})
      when is_integer(amount) and amount > 0 do
    if account.balance_cents >= amount do
      {:ok, %{account | balance_cents: account.balance_cents - amount}}
    else
      {:error, :insufficient_funds}
    end
  end

  def apply_event(%__MODULE__{status: :open} = account, {:frozen, _}) do
    {:ok, %{account | status: :frozen}}
  end

  def apply_event(%__MODULE__{status: :open} = account, {:closed, _}) do
    {:ok, %{account | status: :closed, closed_at: DateTime.utc_now()}}
  end

  def apply_event(%__MODULE__{}, _event), do: {:error, :account_not_open}

  @spec replay(t(), list(event())) :: {:ok, t()} | {:error, atom()}
  def replay(initial, events) when is_list(events) do
    Enum.reduce_while(events, {:ok, initial}, fn event, {:ok, acc} ->
      case apply_event(acc, event) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end

defmodule Banking.AccountCommands do
  @moduledoc """
  Translates incoming requests into validated account events.
  Guards enforce domain constraints before an event is produced.
  """

  alias Banking.Account

  @spec deposit(Account.t(), integer()) :: {:ok, Account.event()} | {:error, atom()}
  def deposit(%Account{}, amount) when not (is_integer(amount) and amount > 0) do
    {:error, :invalid_amount}
  end

  def deposit(%Account{status: :open}, amount) do
    {:ok, {:deposited, %{amount_cents: amount}}}
  end

  def deposit(%Account{}, _amount), do: {:error, :account_not_open}

  @spec withdraw(Account.t(), integer()) :: {:ok, Account.event()} | {:error, atom()}
  def withdraw(%Account{}, amount) when not (is_integer(amount) and amount > 0) do
    {:error, :invalid_amount}
  end

  def withdraw(%Account{status: :open, balance_cents: balance}, amount) when balance >= amount do
    {:ok, {:withdrawn, %{amount_cents: amount}}}
  end

  def withdraw(%Account{status: :open}, _amount), do: {:error, :insufficient_funds}
  def withdraw(%Account{}, _amount), do: {:error, :account_not_open}

  @spec freeze(Account.t(), String.t()) :: {:ok, Account.event()} | {:error, atom()}
  def freeze(%Account{status: :open}, reason) when is_binary(reason) do
    {:ok, {:frozen, %{reason: reason}}}
  end

  def freeze(%Account{}, _reason), do: {:error, :account_not_open}

  @spec close(Account.t()) :: {:ok, Account.event()} | {:error, atom()}
  def close(%Account{status: :open, balance_cents: 0}), do: {:ok, {:closed, %{}}}
  def close(%Account{status: :open}), do: {:error, :balance_must_be_zero}
  def close(%Account{}), do: {:error, :account_not_open}
end
```
