```elixir
defmodule Finance.Money do
  @moduledoc """
  An immutable value object representing an amount of money in a specific
  currency. All amounts are stored as integers in the smallest currency unit
  (e.g., cents for USD, yen for JPY) to avoid floating-point rounding errors.
  Arithmetic operations enforce currency homogeneity; mixing currencies raises
  a descriptive error rather than silently producing wrong results.
  """

  @enforce_keys [:amount, :currency]
  defstruct [:amount, :currency]

  @type t :: %__MODULE__{
          amount: integer(),
          currency: binary()
        }

  @zero_decimal_currencies ~w[JPY KRW VND BIF CLP GNF ISK MGA PYG RWF UGX XAF XOF XPF]

  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------

  @doc """
  Creates a `Money` struct from a minor-unit integer and a 3-letter
  ISO 4217 currency code. Raises `ArgumentError` on invalid input.
  """
  @spec new(integer(), binary()) :: t()
  def new(amount, currency)
      when is_integer(amount) and is_binary(currency) and byte_size(currency) == 3 do
    %__MODULE__{amount: amount, currency: String.upcase(currency)}
  end

  def new(_amount, _currency), do: raise(ArgumentError, "amount must be integer and currency a 3-letter code")

  @doc """
  Creates a zero-amount `Money` value for the given currency.
  """
  @spec zero(binary()) :: t()
  def zero(currency) when is_binary(currency), do: new(0, currency)

  # ---------------------------------------------------------------------------
  # Arithmetic
  # ---------------------------------------------------------------------------

  @doc """
  Adds two `Money` values of the same currency.
  Returns `{:ok, result}` or `{:error, :currency_mismatch}`.
  """
  @spec add(t(), t()) :: {:ok, t()} | {:error, :currency_mismatch}
  def add(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    {:ok, %__MODULE__{amount: a.amount + b.amount, currency: c}}
  end

  def add(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @doc """
  Subtracts `b` from `a`. Both must share the same currency.
  """
  @spec subtract(t(), t()) :: {:ok, t()} | {:error, :currency_mismatch}
  def subtract(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    {:ok, %__MODULE__{amount: a.amount - b.amount, currency: c}}
  end

  def subtract(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @doc """
  Multiplies a `Money` value by a scalar factor. Fractional results are
  rounded to the nearest minor unit using banker's rounding.
  """
  @spec multiply(t(), number()) :: t()
  def multiply(%__MODULE__{} = money, factor) when is_number(factor) do
    raw = money.amount * factor
    rounded = round_half_even(raw)
    %__MODULE__{money | amount: rounded}
  end

  @doc """
  Allocates a `Money` value across a list of ratios, distributing any
  remainder cent-by-cent to avoid losing value through rounding.
  """
  @spec allocate(t(), [number()]) :: [t()] | {:error, :empty_ratios}
  def allocate(_money, []), do: {:error, :empty_ratios}

  def allocate(%__MODULE__{} = money, ratios) when is_list(ratios) do
    total_ratio = Enum.sum(ratios)
    shares = Enum.map(ratios, fn r -> trunc(money.amount * r / total_ratio) end)
    remainder = money.amount - Enum.sum(shares)

    shares
    |> distribute_remainder(remainder)
    |> Enum.map(&%__MODULE__{money | amount: &1})
  end

  # ---------------------------------------------------------------------------
  # Comparison
  # ---------------------------------------------------------------------------

  @doc """
  Compares two same-currency `Money` values. Returns `:lt`, `:eq`, or `:gt`.
  """
  @spec compare(t(), t()) :: :lt | :eq | :gt | {:error, :currency_mismatch}
  def compare(%__MODULE__{currency: c, amount: a}, %__MODULE__{currency: c, amount: b}) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  def compare(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  # ---------------------------------------------------------------------------
  # Formatting
  # ---------------------------------------------------------------------------

  @doc """
  Returns a human-readable string representation, e.g. `"USD 19.99"`.
  Zero-decimal currencies are rendered without a fractional part.
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{amount: amount, currency: currency}) do
    if currency in @zero_decimal_currencies do
      "#{currency} #{amount}"
    else
      major = div(amount, 100)
      minor = abs(rem(amount, 100))
      "#{currency} #{major}.#{String.pad_leading("#{minor}", 2, "0")}"
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp round_half_even(value) do
    floor = trunc(value)
    frac = value - floor

    cond do
      frac > 0.5 -> floor + 1
      frac < 0.5 -> floor
      rem(floor, 2) == 0 -> floor
      true -> floor + 1
    end
  end

  defp distribute_remainder(shares, 0), do: shares

  defp distribute_remainder([h | t], remainder) when remainder > 0 do
    [h + 1 | distribute_remainder(t, remainder - 1)]
  end

  defp distribute_remainder(shares, _remainder), do: shares
end
```
