# File: `example_good_98.md`

```elixir
defmodule Ecto.Type.Money do
  @moduledoc """
  Custom Ecto type that persists monetary values as a composite
  `{amount_cents, currency_code}` tuple stored in a single PostgreSQL
  integer column (cents) alongside a separate currency column.

  Use this type with a virtual field or a custom embedded schema to keep
  currency and amount together at the domain layer while storing them
  as efficient primitives in the database.
  """

  use Ecto.Type

  @type t :: %__MODULE__{
          amount_cents: non_neg_integer(),
          currency: String.t()
        }

  @enforce_keys [:amount_cents, :currency]
  defstruct [:amount_cents, :currency]

  @supported_currencies ~w[USD EUR GBP JPY CAD AUD CHF SEK NOK DKK]

  @impl Ecto.Type
  def type, do: :map

  @impl Ecto.Type
  def cast(%__MODULE__{} = money), do: {:ok, money}

  def cast(%{amount_cents: cents, currency: currency})
      when is_integer(cents) and cents >= 0 and is_binary(currency) do
    validate_and_build(cents, currency)
  end

  def cast(%{"amount_cents" => cents, "currency" => currency})
      when is_integer(cents) and cents >= 0 and is_binary(currency) do
    validate_and_build(cents, currency)
  end

  def cast(_other), do: :error

  @impl Ecto.Type
  def load(%{"amount_cents" => cents, "currency" => currency})
      when is_integer(cents) and is_binary(currency) do
    {:ok, %__MODULE__{amount_cents: cents, currency: currency}}
  end

  def load(_other), do: :error

  @impl Ecto.Type
  def dump(%__MODULE__{amount_cents: cents, currency: currency}) do
    {:ok, %{"amount_cents" => cents, "currency" => currency}}
  end

  def dump(_other), do: :error

  @doc """
  Adds two `Money` values of the same currency.

  Returns `{:ok, result}` or `{:error, :currency_mismatch}`.
  """
  @spec add(t(), t()) :: {:ok, t()} | {:error, :currency_mismatch}
  def add(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    {:ok, %__MODULE__{amount_cents: a.amount_cents + b.amount_cents, currency: c}}
  end

  def add(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @doc """
  Subtracts `b` from `a`, both of the same currency.

  Returns `{:ok, result}` or `{:error, :currency_mismatch}`.
  The result amount is clamped to zero to prevent negative money values.
  """
  @spec subtract(t(), t()) :: {:ok, t()} | {:error, :currency_mismatch}
  def subtract(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    {:ok, %__MODULE__{amount_cents: max(a.amount_cents - b.amount_cents, 0), currency: c}}
  end

  def subtract(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @doc """
  Scales a `Money` value by a numeric multiplier, rounding to the nearest cent.
  """
  @spec multiply(t(), number()) :: t()
  def multiply(%__MODULE__{amount_cents: cents, currency: currency}, factor)
      when is_number(factor) and factor >= 0 do
    %__MODULE__{amount_cents: round(cents * factor), currency: currency}
  end

  @doc """
  Returns the amount formatted as a decimal string, e.g. `"12.34 USD"`.
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{amount_cents: cents, currency: currency}) do
    units = div(cents, 100)
    remainder = rem(cents, 100)
    "#{units}.#{String.pad_leading(Integer.to_string(remainder), 2, "0")} #{currency}"
  end

  @doc """
  Returns `true` when `a` is greater than `b` in the same currency.

  Returns `{:error, :currency_mismatch}` if currencies differ.
  """
  @spec greater_than?(t(), t()) :: boolean() | {:error, :currency_mismatch}
  def greater_than?(%__MODULE__{currency: c, amount_cents: ac}, %__MODULE__{currency: c, amount_cents: bc}) do
    ac > bc
  end

  def greater_than?(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  defp validate_and_build(cents, currency) do
    if String.upcase(currency) in @supported_currencies do
      {:ok, %__MODULE__{amount_cents: cents, currency: String.upcase(currency)}}
    else
      :error
    end
  end
end
```
