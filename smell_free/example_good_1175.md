**File:** `example_good_1175.md`

```elixir
defmodule Money do
  @moduledoc """
  An immutable value object representing a monetary amount in a specific currency.
  All arithmetic operations preserve currency and return new Money structs.
  """

  @enforce_keys [:amount_cents, :currency]
  defstruct [:amount_cents, :currency]

  @type t :: %__MODULE__{
          amount_cents: integer(),
          currency: String.t()
        }

  @spec new(integer(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def new(amount_cents, currency)
      when is_integer(amount_cents) and is_binary(currency) do
    upcased = String.upcase(String.trim(currency))

    if String.match?(upcased, ~r/^[A-Z]{3}$/) do
      {:ok, %__MODULE__{amount_cents: amount_cents, currency: upcased}}
    else
      {:error, "currency must be a 3-letter ISO 4217 code, got: #{currency}"}
    end
  end

  @spec zero(String.t()) :: {:ok, t()} | {:error, String.t()}
  def zero(currency), do: new(0, currency)

  @spec add(t(), t()) :: {:ok, t()} | {:error, :currency_mismatch}
  def add(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    {:ok, %__MODULE__{amount_cents: a.amount_cents + b.amount_cents, currency: c}}
  end

  def add(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @spec subtract(t(), t()) :: {:ok, t()} | {:error, :currency_mismatch}
  def subtract(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    {:ok, %__MODULE__{amount_cents: a.amount_cents - b.amount_cents, currency: c}}
  end

  def subtract(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @spec multiply(t(), number()) :: t()
  def multiply(%__MODULE__{} = money, factor) when is_number(factor) do
    %{money | amount_cents: round(money.amount_cents * factor)}
  end

  @spec negate(t()) :: t()
  def negate(%__MODULE__{} = money) do
    %{money | amount_cents: -money.amount_cents}
  end

  @spec abs(t()) :: t()
  def abs(%__MODULE__{} = money) do
    %{money | amount_cents: Kernel.abs(money.amount_cents)}
  end

  @spec positive?(t()) :: boolean()
  def positive?(%__MODULE__{amount_cents: c}), do: c > 0

  @spec negative?(t()) :: boolean()
  def negative?(%__MODULE__{amount_cents: c}), do: c < 0

  @spec zero?(t()) :: boolean()
  def zero?(%__MODULE__{amount_cents: c}), do: c == 0

  @spec compare(t(), t()) :: :lt | :eq | :gt | {:error, :currency_mismatch}
  def compare(%__MODULE__{currency: c, amount_cents: a}, %__MODULE__{currency: c, amount_cents: b}) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  def compare(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @spec to_decimal_string(t()) :: String.t()
  def to_decimal_string(%__MODULE__{amount_cents: cents, currency: currency}) do
    units = div(cents, 100)
    remainder = rem(Kernel.abs(cents), 100)
    sign = if cents < 0, do: "-", else: ""
    "#{sign}#{currency} #{units}.#{String.pad_leading(to_string(remainder), 2, "0")}"
  end

  @spec sum([t()], String.t()) :: {:ok, t()} | {:error, :currency_mismatch} | {:error, String.t()}
  def sum([], currency), do: zero(currency)

  def sum([%__MODULE__{currency: first_currency} | _] = moneys, currency)
      when first_currency != currency do
    {:error, :currency_mismatch}
  end

  def sum(moneys, currency) do
    with {:ok, zero_value} <- zero(currency) do
      result =
        Enum.reduce_while(moneys, {:ok, zero_value}, fn money, {:ok, acc} ->
          case add(acc, money) do
            {:ok, updated} -> {:cont, {:ok, updated}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      result
    end
  end
end
```
