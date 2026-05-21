# Annotated Example 03

- **Smell name:** Code organization by process
- **Expected smell location:** `Payments.CurrencyConverter` module — `GenServer` implementation
- **Affected functions:** `convert/3`, `to_minor_units/3`, `from_minor_units/3`, `format_amount/3`, `exchange_rate/3`
- **Short explanation:** Currency conversion, unit scaling, and formatting are purely mathematical operations on numbers and lookup tables. The exchange-rate table is read-only data passed at startup and never mutated. There is no concurrent resource to protect and no I/O involved at call time. Wrapping these in a `GenServer` bottlenecks all payment processing threads through a single process unnecessarily.

```elixir
defmodule Payments.CurrencyConverter do
  use GenServer

  @moduledoc """
  Handles currency conversion, minor-unit scaling, and monetary
  formatting for the payments service. Rate tables are loaded from
  configuration at startup and treated as immutable for the process
  lifetime.
  """

  @default_rates %{
    "USD" => 1.0,
    "EUR" => 0.91,
    "GBP" => 0.78,
    "BRL" => 4.97,
    "JPY" => 149.50,
    "CAD" => 1.36,
    "AUD" => 1.53,
    "CHF" => 0.89
  }

  @minor_unit_exponents %{
    "USD" => 2, "EUR" => 2, "GBP" => 2, "BRL" => 2,
    "CAD" => 2, "AUD" => 2, "CHF" => 2, "JPY" => 0
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    {rates, gen_opts} = Keyword.pop(opts, :rates, @default_rates)
    GenServer.start_link(__MODULE__, rates, gen_opts)
  end

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because all operations are pure computations on
  # numbers and static lookup tables. The rates map never changes after init, so
  # there is no shared mutable state to protect. Using a GenServer serializes all
  # conversion calls through one process, creating a bottleneck under concurrent
  # payment processing workloads.

  @doc """
  Converts `amount` from `from_currency` to `to_currency`.
  Returns `{:ok, converted_amount}` or `{:error, reason}`.
  """
  def convert(pid, amount, %{from: from, to: to}) do
    GenServer.call(pid, {:convert, amount, from, to})
  end

  @doc """
  Converts a decimal amount to integer minor units (e.g., cents for USD).
  """
  def to_minor_units(pid, amount, currency) do
    GenServer.call(pid, {:to_minor_units, amount, currency})
  end

  @doc """
  Converts integer minor units back to a decimal amount.
  """
  def from_minor_units(pid, minor_units, currency) do
    GenServer.call(pid, {:from_minor_units, minor_units, currency})
  end

  @doc """
  Formats a decimal amount as a human-readable monetary string.
  """
  def format_amount(pid, amount, currency) do
    GenServer.call(pid, {:format_amount, amount, currency})
  end

  @doc "Returns the exchange rate between two currencies."
  def exchange_rate(pid, from, to) do
    GenServer.call(pid, {:exchange_rate, from, to})
  end

  # VALIDATION: SMELL END

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(rates), do: {:ok, rates}

  @impl true
  def handle_call({:convert, amount, from, to}, _from, rates) do
    with {:ok, from_rate} <- fetch_rate(rates, from),
         {:ok, to_rate}   <- fetch_rate(rates, to) do
      converted = Float.round(amount * (to_rate / from_rate), 6)
      {:reply, {:ok, converted}, rates}
    else
      error -> {:reply, error, rates}
    end
  end

  @impl true
  def handle_call({:to_minor_units, amount, currency}, _from, rates) do
    exponent = Map.get(@minor_unit_exponents, currency, 2)
    factor = :math.pow(10, exponent) |> round()
    minor = round(amount * factor)
    {:reply, {:ok, minor}, rates}
  end

  @impl true
  def handle_call({:from_minor_units, minor_units, currency}, _from, rates) do
    exponent = Map.get(@minor_unit_exponents, currency, 2)
    factor = :math.pow(10, exponent)
    amount = Float.round(minor_units / factor, exponent)
    {:reply, {:ok, amount}, rates}
  end

  @impl true
  def handle_call({:format_amount, amount, currency}, _from, rates) do
    exponent = Map.get(@minor_unit_exponents, currency, 2)
    formatted = :erlang.float_to_binary(amount / 1.0, decimals: exponent)
    {:reply, {:ok, "#{currency} #{formatted}"}, rates}
  end

  @impl true
  def handle_call({:exchange_rate, from, to}, _from, rates) do
    with {:ok, from_rate} <- fetch_rate(rates, from),
         {:ok, to_rate}   <- fetch_rate(rates, to) do
      {:reply, {:ok, Float.round(to_rate / from_rate, 6)}, rates}
    else
      error -> {:reply, error, rates}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_rate(rates, currency) do
    case Map.fetch(rates, currency) do
      {:ok, rate} -> {:ok, rate}
      :error -> {:error, {:unknown_currency, currency}}
    end
  end
end
```
