**File:** `example_good_1072.md`

```elixir
defmodule Finance.Money do
  @moduledoc """
  Immutable value object representing a monetary amount in a specific currency.
  Arithmetic operations enforce currency matching and return new `Money` structs.
  All amounts are stored as integer cents to avoid floating-point representation issues.
  """

  @enforce_keys [:amount_cents, :currency]
  defstruct [:amount_cents, :currency]

  @type t :: %__MODULE__{
          amount_cents: integer(),
          currency: String.t()
        }

  @supported_currencies ~w(USD EUR GBP JPY CAD AUD CHF SGD)

  @spec new(integer(), String.t()) :: {:ok, t()} | {:error, term()}
  def new(amount_cents, currency)
      when is_integer(amount_cents) and is_binary(currency) do
    upcased = String.upcase(currency)

    cond do
      upcased not in @supported_currencies ->
        {:error, {:unsupported_currency, currency}}

      amount_cents < 0 ->
        {:error, {:negative_amount, amount_cents}}

      true ->
        {:ok, %__MODULE__{amount_cents: amount_cents, currency: upcased}}
    end
  end

  @spec add(t(), t()) :: {:ok, t()} | {:error, :currency_mismatch}
  def add(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    {:ok, %__MODULE__{amount_cents: a.amount_cents + b.amount_cents, currency: c}}
  end

  def add(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @spec subtract(t(), t()) :: {:ok, t()} | {:error, :currency_mismatch | :insufficient_funds}
  def subtract(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    result = a.amount_cents - b.amount_cents

    if result >= 0 do
      {:ok, %__MODULE__{amount_cents: result, currency: c}}
    else
      {:error, :insufficient_funds}
    end
  end

  def subtract(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @spec multiply(t(), number()) :: {:ok, t()} | {:error, :negative_factor}
  def multiply(%__MODULE__{} = money, factor) when is_number(factor) and factor >= 0 do
    rounded = round(money.amount_cents * factor)
    {:ok, %__MODULE__{amount_cents: rounded, currency: money.currency}}
  end

  def multiply(%__MODULE__{}, factor) when is_number(factor) and factor < 0 do
    {:error, :negative_factor}
  end

  @spec zero?(t()) :: boolean()
  def zero?(%__MODULE__{amount_cents: 0}), do: true
  def zero?(%__MODULE__{}), do: false

  @spec positive?(t()) :: boolean()
  def positive?(%__MODULE__{amount_cents: cents}), do: cents > 0

  @spec compare(t(), t()) :: :lt | :eq | :gt | {:error, :currency_mismatch}
  def compare(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    cond do
      a.amount_cents < b.amount_cents -> :lt
      a.amount_cents == b.amount_cents -> :eq
      true -> :gt
    end
  end

  def compare(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @spec to_decimal(t()) :: Decimal.t()
  def to_decimal(%__MODULE__{amount_cents: cents}) do
    Decimal.div(Decimal.new(cents), Decimal.new(100))
  end

  @spec format(t()) :: String.t()
  def format(%__MODULE__{amount_cents: cents, currency: currency}) do
    major = div(cents, 100)
    minor = rem(cents, 100)
    "#{currency} #{major}.#{String.pad_leading(Integer.to_string(minor), 2, "0")}"
  end

  defimpl Inspect do
    def inspect(%Finance.Money{} = m, _opts) do
      "#Money<#{Finance.Money.format(m)}>"
    end
  end
end
```
