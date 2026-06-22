```elixir
defmodule Finance.Money do
  @moduledoc """
  Immutable value object representing a monetary amount in a specific currency.
  All arithmetic is performed in integer cents to avoid floating-point errors.
  Conversion rates are accepted explicitly at call time rather than pulled
  from global configuration.
  """

  @type currency_code :: String.t()

  @type t :: %__MODULE__{
          amount_cents: integer(),
          currency: currency_code()
        }

  @enforce_keys [:amount_cents, :currency]
  defstruct [:amount_cents, :currency]

  @currency_decimals %{
    "USD" => 2, "EUR" => 2, "GBP" => 2, "JPY" => 0,
    "BRL" => 2, "CHF" => 2, "CAD" => 2, "AUD" => 2
  }

  @spec new(integer(), currency_code()) :: {:ok, t()} | {:error, String.t()}
  def new(amount_cents, currency)
      when is_integer(amount_cents) and is_binary(currency) do
    if Map.has_key?(@currency_decimals, String.upcase(currency)) do
      {:ok, %__MODULE__{amount_cents: amount_cents, currency: String.upcase(currency)}}
    else
      {:error, "unsupported currency: #{currency}"}
    end
  end

  @spec from_decimal(float(), currency_code()) :: {:ok, t()} | {:error, String.t()}
  def from_decimal(amount, currency) when is_float(amount) and is_binary(currency) do
    decimals = Map.get(@currency_decimals, String.upcase(currency))

    if is_nil(decimals) do
      {:error, "unsupported currency: #{currency}"}
    else
      cents = round(amount * :math.pow(10, decimals))
      new(cents, currency)
    end
  end

  @spec add(t(), t()) :: {:ok, t()} | {:error, String.t()}
  def add(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    {:ok, %__MODULE__{amount_cents: a.amount_cents + b.amount_cents, currency: c}}
  end

  def add(%__MODULE__{currency: a}, %__MODULE__{currency: b}) do
    {:error, "cannot add #{a} and #{b}: currencies differ"}
  end

  @spec subtract(t(), t()) :: {:ok, t()} | {:error, String.t()}
  def subtract(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    {:ok, %__MODULE__{amount_cents: a.amount_cents - b.amount_cents, currency: c}}
  end

  def subtract(%__MODULE__{currency: a}, %__MODULE__{currency: b}) do
    {:error, "cannot subtract #{a} and #{b}: currencies differ"}
  end

  @spec multiply(t(), number()) :: {:ok, t()} | {:error, String.t()}
  def multiply(%__MODULE__{} = money, factor) when is_number(factor) and factor >= 0 do
    {:ok, %__MODULE__{money | amount_cents: round(money.amount_cents * factor)}}
  end

  def multiply(%__MODULE__{}, factor) when is_number(factor) do
    {:error, "factor must be non-negative, got: #{factor}"}
  end

  @spec convert(t(), currency_code(), float()) :: {:ok, t()} | {:error, String.t()}
  def convert(%__MODULE__{} = money, target_currency, exchange_rate)
      when is_binary(target_currency) and is_float(exchange_rate) and exchange_rate > 0.0 do
    target = String.upcase(target_currency)

    if Map.has_key?(@currency_decimals, target) do
      converted_cents = round(money.amount_cents * exchange_rate)
      {:ok, %__MODULE__{amount_cents: converted_cents, currency: target}}
    else
      {:error, "unsupported target currency: #{target_currency}"}
    end
  end

  @spec zero(currency_code()) :: {:ok, t()} | {:error, String.t()}
  def zero(currency) when is_binary(currency), do: new(0, currency)

  @spec negative?(t()) :: boolean()
  def negative?(%__MODULE__{amount_cents: cents}), do: cents < 0

  @spec positive?(t()) :: boolean()
  def positive?(%__MODULE__{amount_cents: cents}), do: cents > 0

  @spec eq?(t(), t()) :: boolean()
  def eq?(%__MODULE__{currency: c, amount_cents: a}, %__MODULE__{currency: c, amount_cents: a}), do: true
  def eq?(%__MODULE__{}, %__MODULE__{}), do: false

  @spec compare(t(), t()) :: :lt | :eq | :gt | {:error, String.t()}
  def compare(%__MODULE__{currency: c, amount_cents: a}, %__MODULE__{currency: c, amount_cents: b}) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  def compare(%__MODULE__{currency: a}, %__MODULE__{currency: b}) do
    {:error, "cannot compare #{a} and #{b}: currencies differ"}
  end

  @spec format(t()) :: String.t()
  def format(%__MODULE__{amount_cents: cents, currency: currency}) do
    decimals = Map.fetch!(@currency_decimals, currency)
    format_amount(cents, currency, decimals)
  end

  @spec format_amount(integer(), currency_code(), non_neg_integer()) :: String.t()
  defp format_amount(cents, currency, 0) do
    "#{currency} #{cents}"
  end

  defp format_amount(cents, currency, decimals) do
    divisor = round(:math.pow(10, decimals))
    major = div(abs(cents), divisor)
    minor = rem(abs(cents), divisor)
    sign = if cents < 0, do: "-", else: ""
    "#{sign}#{currency} #{major}.#{String.pad_leading(to_string(minor), decimals, "0")}"
  end
end
```
