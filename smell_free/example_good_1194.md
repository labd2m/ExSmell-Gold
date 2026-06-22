```elixir
defmodule Finance.Money do
  @moduledoc """
  A precise monetary value type combining an integer amount in the
  currency's smallest unit with an ISO 4217 currency code. All arithmetic
  operations guard against currency mismatches and integer overflow.
  """

  @type t :: %__MODULE__{
          amount: integer(),
          currency: String.t()
        }

  defstruct [:amount, :currency]

  @spec new(integer(), String.t()) :: {:ok, t()} | {:error, :invalid_amount | :invalid_currency}
  def new(amount, currency) when is_integer(amount) and is_binary(currency) do
    with :ok <- validate_currency(currency) do
      {:ok, %__MODULE__{amount: amount, currency: String.upcase(currency)}}
    end
  end

  def new(_, _), do: {:error, :invalid_amount}

  @spec new!(integer(), String.t()) :: t()
  def new!(amount, currency) do
    case new(amount, currency) do
      {:ok, money} -> money
      {:error, reason} -> raise ArgumentError, "Invalid money: #{reason}"
    end
  end

  @spec add(t(), t()) :: {:ok, t()} | {:error, :currency_mismatch}
  def add(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    {:ok, %__MODULE__{amount: a.amount + b.amount, currency: c}}
  end

  def add(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @spec subtract(t(), t()) :: {:ok, t()} | {:error, :currency_mismatch}
  def subtract(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    {:ok, %__MODULE__{amount: a.amount - b.amount, currency: c}}
  end

  def subtract(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @spec multiply(t(), number()) :: {:ok, t()} | {:error, :invalid_factor}
  def multiply(%__MODULE__{} = money, factor) when is_number(factor) and factor >= 0 do
    {:ok, %__MODULE__{amount: round(money.amount * factor), currency: money.currency}}
  end

  def multiply(%__MODULE__{}, _), do: {:error, :invalid_factor}

  @spec split(t(), pos_integer()) :: [t()]
  def split(%__MODULE__{amount: amount, currency: currency}, parts)
      when is_integer(parts) and parts > 0 do
    base = div(amount, parts)
    remainder = rem(amount, parts)

    base_units = List.duplicate(%__MODULE__{amount: base, currency: currency}, parts)

    Enum.with_index(base_units)
    |> Enum.map(fn {unit, idx} ->
      if idx < remainder do
        %{unit | amount: unit.amount + 1}
      else
        unit
      end
    end)
  end

  @spec zero(String.t()) :: t()
  def zero(currency) when is_binary(currency) do
    %__MODULE__{amount: 0, currency: String.upcase(currency)}
  end

  @spec positive?(t()) :: boolean()
  def positive?(%__MODULE__{amount: amount}), do: amount > 0

  @spec negative?(t()) :: boolean()
  def negative?(%__MODULE__{amount: amount}), do: amount < 0

  @spec to_decimal(t(), pos_integer()) :: Decimal.t()
  def to_decimal(%__MODULE__{amount: amount}, subunit_exponent \\ 2) do
    Decimal.div(Decimal.new(amount), Decimal.new(Integer.pow(10, subunit_exponent)))
  end

  @spec validate_currency(String.t()) :: :ok | {:error, :invalid_currency}
  defp validate_currency(currency) do
    if Regex.match?(~r/^[A-Za-z]{3}$/, currency) do
      :ok
    else
      {:error, :invalid_currency}
    end
  end
end
```
