```elixir
defmodule Store.Money do
  @moduledoc """
  Value object representing a monetary amount with an explicit ISO 4217
  currency code. All amounts are stored as integer cents to avoid
  floating-point precision loss during arithmetic.
  """

  @enforce_keys [:amount_cents, :currency]
  defstruct [:amount_cents, :currency]

  @type t :: %__MODULE__{
          amount_cents: non_neg_integer(),
          currency: String.t()
        }

  @doc "Builds a Money struct from an integer cent amount and currency code."
  @spec new(non_neg_integer(), String.t()) :: t()
  def new(amount_cents, currency)
      when is_integer(amount_cents) and amount_cents >= 0 and is_binary(currency) do
    %__MODULE__{amount_cents: amount_cents, currency: String.upcase(currency)}
  end

  @doc "Builds a Money struct from a float dollar amount and currency code."
  @spec from_float(float(), String.t()) :: t()
  def from_float(amount, currency) when is_float(amount) and amount >= 0.0 and is_binary(currency) do
    %__MODULE__{amount_cents: round(amount * 100), currency: String.upcase(currency)}
  end

  @doc "Adds two same-currency Money values."
  @spec add(t(), t()) :: {:ok, t()} | {:error, :currency_mismatch}
  def add(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    {:ok, %__MODULE__{amount_cents: a.amount_cents + b.amount_cents, currency: c}}
  end

  def add(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @doc "Subtracts `b` from `a`. Returns `{:error, :insufficient_funds}` when `b` exceeds `a`."
  @spec subtract(t(), t()) :: {:ok, t()} | {:error, :currency_mismatch | :insufficient_funds}
  def subtract(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b) do
    if a.amount_cents >= b.amount_cents do
      {:ok, %__MODULE__{amount_cents: a.amount_cents - b.amount_cents, currency: c}}
    else
      {:error, :insufficient_funds}
    end
  end

  def subtract(%__MODULE__{}, %__MODULE__{}), do: {:error, :currency_mismatch}

  @doc "Multiplies a Money value by a non-negative integer factor."
  @spec multiply(t(), non_neg_integer()) :: t()
  def multiply(%__MODULE__{} = money, factor)
      when is_integer(factor) and factor >= 0 do
    %__MODULE__{money | amount_cents: money.amount_cents * factor}
  end

  @doc "Returns `true` when both values share the same currency and amount."
  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{} = a, %__MODULE__{} = b) do
    a.amount_cents == b.amount_cents and a.currency == b.currency
  end

  @doc "Formats a Money value as a human-readable string, e.g. `USD 12.99`."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{amount_cents: cents, currency: currency}) do
    dollars = div(cents, 100)
    remainder = rem(cents, 100)
    "#{currency} #{dollars}.#{String.pad_leading(Integer.to_string(remainder), 2, "0")}"
  end

  @doc "Returns `true` when the amount is zero."
  @spec zero?(t()) :: boolean()
  def zero?(%__MODULE__{amount_cents: 0}), do: true
  def zero?(%__MODULE__{}), do: false
end

defmodule Store.Types.Money do
  @moduledoc """
  Custom Ecto type persisting `Store.Money` structs as JSONB maps in the
  database. The canonical storage shape is `%{"amount_cents" => integer,
  "currency" => string}`.
  """
  use Ecto.Type

  alias Store.Money

  @impl Ecto.Type
  def type, do: :map

  @impl Ecto.Type
  def cast(%Money{} = money), do: {:ok, money}

  def cast(%{"amount_cents" => cents, "currency" => currency})
      when is_integer(cents) and cents >= 0 and is_binary(currency),
      do: {:ok, Money.new(cents, currency)}

  def cast(%{amount_cents: cents, currency: currency})
      when is_integer(cents) and cents >= 0 and is_binary(currency),
      do: {:ok, Money.new(cents, currency)}

  def cast(_), do: :error

  @impl Ecto.Type
  def load(%{"amount_cents" => cents, "currency" => currency})
      when is_integer(cents) and is_binary(currency),
      do: {:ok, Money.new(cents, currency)}

  def load(_), do: :error

  @impl Ecto.Type
  def dump(%Money{amount_cents: cents, currency: currency}),
    do: {:ok, %{"amount_cents" => cents, "currency" => currency}}

  def dump(_), do: :error

  @impl Ecto.Type
  def equal?(a, b), do: Money.equal?(a, b)
end
```
