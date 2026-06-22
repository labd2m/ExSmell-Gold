```elixir
defmodule Finbank.Ledger.Entry do
  @moduledoc """
  Represents an immutable double-entry ledger record for financial transactions.
  Each entry captures debit and credit legs with full audit metadata.
  """

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          amount_cents: pos_integer(),
          currency: String.t(),
          direction: :debit | :credit,
          reference: String.t(),
          recorded_at: DateTime.t()
        }

  defstruct [:id, :account_id, :amount_cents, :currency, :direction, :reference, :recorded_at]

  @doc """
  Constructs a validated ledger entry from raw input.

  Returns `{:ok, entry}` on success or `{:error, reason}` when validation fails.
  """
  @spec new(map()) :: {:ok, t()} | {:error, String.t()}
  def new(params) when is_map(params) do
    with {:ok, account_id} <- fetch_uuid(params, :account_id),
         {:ok, amount_cents} <- fetch_positive_integer(params, :amount_cents),
         {:ok, currency} <- fetch_currency(params, :currency),
         {:ok, direction} <- fetch_direction(params, :direction),
         {:ok, reference} <- fetch_string(params, :reference) do
      entry = %__MODULE__{
        id: Ecto.UUID.generate(),
        account_id: account_id,
        amount_cents: amount_cents,
        currency: currency,
        direction: direction,
        reference: reference,
        recorded_at: DateTime.utc_now()
      }

      {:ok, entry}
    end
  end

  @doc """
  Returns the signed integer value of the entry: positive for credits, negative for debits.
  """
  @spec signed_amount(t()) :: integer()
  def signed_amount(%__MODULE__{direction: :credit, amount_cents: a}), do: a
  def signed_amount(%__MODULE__{direction: :debit, amount_cents: a}), do: -a

  @doc """
  Returns true when two entries represent a balanced debit/credit pair.
  """
  @spec balanced_pair?(t(), t()) :: boolean()
  def balanced_pair?(
        %__MODULE__{amount_cents: a, currency: c, direction: :debit},
        %__MODULE__{amount_cents: a, currency: c, direction: :credit}
      ),
      do: true

  def balanced_pair?(%__MODULE__{}, %__MODULE__{}), do: false

  defp fetch_uuid(params, key) do
    case Map.fetch(params, key) do
      {:ok, val} when is_binary(val) -> {:ok, val}
      {:ok, _} -> {:error, "#{key} must be a binary UUID"}
      :error -> {:error, "#{key} is required"}
    end
  end

  defp fetch_positive_integer(params, key) do
    case Map.fetch(params, key) do
      {:ok, val} when is_integer(val) and val > 0 -> {:ok, val}
      {:ok, _} -> {:error, "#{key} must be a positive integer"}
      :error -> {:error, "#{key} is required"}
    end
  end

  defp fetch_currency(params, key) do
    case Map.fetch(params, key) do
      {:ok, val} when is_binary(val) and byte_size(val) == 3 -> {:ok, String.upcase(val)}
      {:ok, _} -> {:error, "#{key} must be a 3-character currency code"}
      :error -> {:error, "#{key} is required"}
    end
  end

  defp fetch_direction(params, key) do
    case Map.fetch(params, key) do
      {:ok, dir} when dir in [:debit, :credit] -> {:ok, dir}
      {:ok, _} -> {:error, "#{key} must be :debit or :credit"}
      :error -> {:error, "#{key} is required"}
    end
  end

  defp fetch_string(params, key) do
    case Map.fetch(params, key) do
      {:ok, val} when is_binary(val) and val != "" -> {:ok, val}
      {:ok, _} -> {:error, "#{key} must be a non-empty string"}
      :error -> {:error, "#{key} is required"}
    end
  end
end
```
