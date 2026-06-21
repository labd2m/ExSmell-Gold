```elixir
defmodule Finance.Money do
  @moduledoc """
  Represents a monetary amount with an explicit ISO 4217 currency code.
  All arithmetic operations return new `Money` structs rather than raw
  numeric values, keeping the currency constraint integral to the type.
  Mixed-currency operations raise `ArgumentError` to prevent silent
  incorrect results.
  """

  @enforce_keys [:amount_cents, :currency]
  defstruct [:amount_cents, :currency]

  @type t :: %__MODULE__{
          amount_cents: integer(),
          currency: String.t()
        }

  @supported_currencies ~w(USD EUR GBP BRL JPY CAD AUD CHF)

  @doc """
  Creates a new `Money` struct from a major-unit amount and a currency code.
  Returns `{:error, :unsupported_currency}` for unknown currencies.
  """
  @spec new(number(), String.t()) :: {:ok, t()} | {:error, :unsupported_currency}
  def new(amount, currency) when is_number(amount) and is_binary(currency) do
    upcased = String.upcase(currency)

    if upcased in @supported_currencies do
      cents = Float.round(amount * 1.0, 2) |> then(&round(&1 * 100))
      {:ok, %__MODULE__{amount_cents: cents, currency: upcased}}
    else
      {:error, :unsupported_currency}
    end
  end

  @doc "Adds two `Money` values. Raises on currency mismatch."
  @spec add(t(), t()) :: t()
  def add(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    %__MODULE__{amount_cents: a.amount_cents + b.amount_cents, currency: c}
  end

  def add(%__MODULE__{currency: ca}, %__MODULE__{currency: cb}) do
    raise ArgumentError, "Cannot add #{ca} and #{cb}: currency mismatch"
  end

  @doc "Subtracts `b` from `a`. Raises on currency mismatch."
  @spec subtract(t(), t()) :: t()
  def subtract(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    %__MODULE__{amount_cents: a.amount_cents - b.amount_cents, currency: c}
  end

  def subtract(%__MODULE__{currency: ca}, %__MODULE__{currency: cb}) do
    raise ArgumentError, "Cannot subtract #{cb} from #{ca}: currency mismatch"
  end

  @doc "Multiplies a `Money` amount by a numeric scalar. Rounds to the nearest cent."
  @spec multiply(t(), number()) :: t()
  def multiply(%__MODULE__{} = money, factor) when is_number(factor) do
    %__MODULE__{amount_cents: round(money.amount_cents * factor), currency: money.currency}
  end

  @doc "Returns the amount as a human-readable decimal string, e.g. `10.50 USD`."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{amount_cents: cents, currency: currency}) do
    major = div(abs(cents), 100)
    minor = rem(abs(cents), 100)
    sign = if cents < 0, do: "-", else: ""
    "#{sign}#{major}.#{String.pad_leading(to_string(minor), 2, "0")} #{currency}"
  end

  @doc "Returns true when the amount is strictly greater than zero."
  @spec positive?(t()) :: boolean()
  def positive?(%__MODULE__{amount_cents: cents}), do: cents > 0

  @doc "Returns true when the amount is exactly zero."
  @spec zero?(t()) :: boolean()
  def zero?(%__MODULE__{amount_cents: cents}), do: cents == 0

  @doc "Returns true when the amount is negative."
  @spec negative?(t()) :: boolean()
  def negative?(%__MODULE__{amount_cents: cents}), do: cents < 0

  @doc "Compares two `Money` values of the same currency. Returns `:lt`, `:eq`, or `:gt`."
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{currency: c, amount_cents: a}, %__MODULE__{currency: c, amount_cents: b}) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  def compare(%__MODULE__{currency: ca}, %__MODULE__{currency: cb}) do
    raise ArgumentError, "Cannot compare #{ca} and #{cb}: currency mismatch"
  end
end
```
