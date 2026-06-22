```elixir
defmodule Money do
  @moduledoc """
  An immutable value object representing a monetary amount in a specific currency.
  All arithmetic preserves currency consistency and uses integer cent arithmetic
  to avoid floating-point rounding errors.
  """

  @type t :: %__MODULE__{amount_cents: integer(), currency: String.t()}

  defstruct [:amount_cents, :currency]

  @spec new(integer(), String.t()) :: {:ok, t()} | {:error, :invalid_currency | :invalid_amount}
  def new(amount_cents, currency)
      when is_integer(amount_cents) and is_binary(currency) do
    cond do
      String.length(currency) != 3 -> {:error, :invalid_currency}
      true ->
        {:ok, %__MODULE__{amount_cents: amount_cents, currency: String.upcase(currency)}}
    end
  end

  def new(_amount_cents, _currency), do: {:error, :invalid_amount}

  @spec add(t(), t()) :: {:ok, t()} | {:error, :currency_mismatch}
  def add(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    {:ok, %{a | amount_cents: a.amount_cents + b.amount_cents}}
  end

  def add(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @spec subtract(t(), t()) :: {:ok, t()} | {:error, :currency_mismatch}
  def subtract(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    {:ok, %{a | amount_cents: a.amount_cents - b.amount_cents}}
  end

  def subtract(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @spec multiply(t(), number()) :: {:ok, t()}
  def multiply(%__MODULE__{} = money, factor) when is_number(factor) do
    {:ok, %{money | amount_cents: round(money.amount_cents * factor)}}
  end

  @spec negate(t()) :: t()
  def negate(%__MODULE__{} = money), do: %{money | amount_cents: -money.amount_cents}

  @spec zero?(t()) :: boolean()
  def zero?(%__MODULE__{amount_cents: 0}), do: true
  def zero?(%__MODULE__{}), do: false

  @spec positive?(t()) :: boolean()
  def positive?(%__MODULE__{amount_cents: c}), do: c > 0

  @spec negative?(t()) :: boolean()
  def negative?(%__MODULE__{amount_cents: c}), do: c < 0

  @spec to_decimal_string(t()) :: String.t()
  def to_decimal_string(%__MODULE__{amount_cents: cents, currency: currency}) do
    sign = if cents < 0, do: "-", else: ""
    abs_cents = abs(cents)
    dollars = div(abs_cents, 100)
    remaining = rem(abs_cents, 100)
    "#{sign}#{currency} #{dollars}.#{String.pad_leading(Integer.to_string(remaining), 2, "0")}"
  end

  @spec sum([t()], String.t()) :: {:ok, t()} | {:error, :currency_mismatch | :empty_list}
  def sum([], _currency), do: {:error, :empty_list}

  def sum(monies, currency) when is_list(monies) and is_binary(currency) do
    upper = String.upcase(currency)

    if Enum.all?(monies, &(&1.currency == upper)) do
      total = Enum.reduce(monies, 0, fn m, acc -> acc + m.amount_cents end)
      {:ok, %__MODULE__{amount_cents: total, currency: upper}}
    else
      {:error, :currency_mismatch}
    end
  end
end
```
