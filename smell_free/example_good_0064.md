```elixir
defmodule Finance.Money do
  @moduledoc """
  Represents a monetary amount as an integer number of minor units
  paired with an ISO 4217 currency code.

  Storing amounts as integers (e.g. 1099 for $10.99) eliminates
  floating-point rounding issues. Mixed-currency arithmetic is explicitly
  rejected to prevent silent data integrity problems. All operations
  that may fail return tagged tuples; formatting helpers always succeed.
  """

  @type t :: %__MODULE__{
          amount: integer(),
          currency: String.t()
        }

  defstruct [:amount, :currency]

  @spec new(integer(), String.t()) :: {:ok, t()} | {:error, :invalid_currency}
  def new(amount, currency) when is_integer(amount) and is_binary(currency) do
    normalized = String.upcase(currency)

    if valid_currency_code?(normalized) do
      {:ok, %__MODULE__{amount: amount, currency: normalized}}
    else
      {:error, :invalid_currency}
    end
  end

  @spec add(t(), t()) :: {:ok, t()} | {:error, :currency_mismatch}
  def add(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    {:ok, %{a | amount: a.amount + b.amount}}
  end

  def add(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @spec subtract(t(), t()) :: {:ok, t()} | {:error, :currency_mismatch}
  def subtract(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    {:ok, %{a | amount: a.amount - b.amount}}
  end

  def subtract(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @spec scale(t(), integer()) :: t()
  def scale(%__MODULE__{} = money, factor) when is_integer(factor) do
    %{money | amount: money.amount * factor}
  end

  @spec compare(t(), t()) :: :lt | :eq | :gt | {:error, :currency_mismatch}
  def compare(%__MODULE__{currency: c, amount: a}, %__MODULE__{currency: c, amount: b}) do
    cond do
      a < b -> :lt
      a == b -> :eq
      true -> :gt
    end
  end

  def compare(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @spec zero?(t()) :: boolean()
  def zero?(%__MODULE__{amount: 0}), do: true
  def zero?(%__MODULE__{}), do: false

  @spec negative?(t()) :: boolean()
  def negative?(%__MODULE__{amount: a}), do: a < 0

  @spec abs(t()) :: t()
  def abs(%__MODULE__{amount: a} = money), do: %{money | amount: Kernel.abs(a)}

  @spec format(t()) :: String.t()
  def format(%__MODULE__{amount: amount, currency: currency}) do
    sign = if amount < 0, do: "-", else: ""
    units = div(Kernel.abs(amount), 100)
    cents = rem(Kernel.abs(amount), 100)
    "#{sign}#{currency} #{units}.#{String.pad_leading(Integer.to_string(cents), 2, "0")}"
  end

  defp valid_currency_code?(code), do: String.match?(code, ~r/\A[A-Z]{3}\z/)
end

defimpl String.Chars, for: Finance.Money do
  def to_string(money), do: Finance.Money.format(money)
end

defimpl Inspect, for: Finance.Money do
  def inspect(money, _opts) do
    "#Money<#{Finance.Money.format(money)}>"
  end
end

defimpl Jason.Encoder, for: Finance.Money do
  def encode(money, opts) do
    Jason.Encoder.encode(
      %{"amount" => money.amount, "currency" => money.currency},
      opts
    )
  end
end
```
