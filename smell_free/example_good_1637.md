```elixir
defmodule Finance.Money do
  @moduledoc """
  Immutable value object representing a monetary amount in a specific currency.

  All arithmetic operations preserve currency consistency and return typed
  results. Mixed-currency operations return an error rather than silently
  converting or truncating values.
  """

  @enforce_keys [:amount_cents, :currency]
  defstruct [:amount_cents, :currency]

  @type t :: %__MODULE__{
          amount_cents: integer(),
          currency: String.t()
        }

  @doc """
  Creates a new Money value from a cents integer and ISO 4217 currency code.
  """
  @spec new(integer(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def new(amount_cents, currency)
      when is_integer(amount_cents) and is_binary(currency) and byte_size(currency) == 3 do
    {:ok, %__MODULE__{amount_cents: amount_cents, currency: String.upcase(currency)}}
  end

  def new(_, _), do: {:error, "amount must be an integer and currency a 3-letter code"}

  @doc """
  Adds two Money values of the same currency.
  """
  @spec add(t(), t()) :: {:ok, t()} | {:error, String.t()}
  def add(%__MODULE__{currency: c, amount_cents: a}, %__MODULE__{currency: c, amount_cents: b}) do
    {:ok, %__MODULE__{amount_cents: a + b, currency: c}}
  end

  def add(%__MODULE__{currency: c1}, %__MODULE__{currency: c2}) do
    {:error, "cannot add #{c1} and #{c2}"}
  end

  @doc """
  Subtracts one Money value from another of the same currency.
  """
  @spec subtract(t(), t()) :: {:ok, t()} | {:error, String.t()}
  def subtract(%__MODULE__{currency: c, amount_cents: a}, %__MODULE__{currency: c, amount_cents: b}) do
    {:ok, %__MODULE__{amount_cents: a - b, currency: c}}
  end

  def subtract(%__MODULE__{currency: c1}, %__MODULE__{currency: c2}) do
    {:error, "cannot subtract #{c2} from #{c1}"}
  end

  @doc """
  Multiplies a Money value by a numeric factor.
  """
  @spec multiply(t(), number()) :: {:ok, t()} | {:error, String.t()}
  def multiply(%__MODULE__{} = money, factor) when is_number(factor) and factor >= 0 do
    {:ok, %__MODULE__{money | amount_cents: round(money.amount_cents * factor)}}
  end

  def multiply(_, _), do: {:error, "factor must be a non-negative number"}

  @doc """
  Returns the absolute value of a Money amount.
  """
  @spec abs(t()) :: t()
  def abs(%__MODULE__{} = money), do: %{money | amount_cents: Kernel.abs(money.amount_cents)}

  @doc """
  Compares two Money values of the same currency.

  Returns `:lt`, `:eq`, or `:gt`, or an error for mismatched currencies.
  """
  @spec compare(t(), t()) :: {:ok, :lt | :eq | :gt} | {:error, String.t()}
  def compare(%__MODULE__{currency: c, amount_cents: a}, %__MODULE__{currency: c, amount_cents: b}) do
    result = cond do
      a < b -> :lt
      a == b -> :eq
      true -> :gt
    end

    {:ok, result}
  end

  def compare(%__MODULE__{currency: c1}, %__MODULE__{currency: c2}) do
    {:error, "cannot compare #{c1} and #{c2}"}
  end

  @doc """
  Formats a Money value as a human-readable string (e.g., `"USD 12.50"`).
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{amount_cents: cents, currency: cur}) do
    whole = div(Kernel.abs(cents), 100)
    fraction = rem(Kernel.abs(cents), 100)
    sign = if cents < 0, do: "-", else: ""
    "#{cur} #{sign}#{whole}.#{String.pad_leading(to_string(fraction), 2, "0")}"
  end

  @doc """
  Returns true if the amount is zero.
  """
  @spec zero?(t()) :: boolean()
  def zero?(%__MODULE__{amount_cents: 0}), do: true
  def zero?(%__MODULE__{}), do: false

  @doc """
  Returns true if the amount is negative.
  """
  @spec negative?(t()) :: boolean()
  def negative?(%__MODULE__{amount_cents: a}), do: a < 0
end
```
