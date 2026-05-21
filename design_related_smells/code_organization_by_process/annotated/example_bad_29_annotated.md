# Annotated Example — Code Smell: Code Organization by Process

| Field | Value |
|---|---|
| **Smell name** | Code organization by process |
| **Expected smell location** | `CurrencyConverter` module — entire GenServer structure |
| **Affected function(s)** | `convert/3`, `supported_currencies/1`, `exchange_rate/3`, `handle_call/3` |
| **Short explanation** | All operations in this module are pure, stateless calculations (looking up rates and multiplying). There is no shared mutable state, no concurrency requirement, and no I/O scheduling need. Wrapping these operations inside a GenServer forces every call to serialize through a single process, creating a potential bottleneck without any benefit. |

```elixir
defmodule Billing.CurrencyConverter do
  use GenServer

  @moduledoc """
  Provides currency conversion utilities for the billing system.
  Converts amounts between supported fiat currencies using static
  exchange rates loaded at startup.
  """

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because the module performs pure arithmetic
  # (rate lookup + multiplication). No runtime state is mutated between calls,
  # no concurrency is needed, and no shared resource is accessed. Routing every
  # conversion through a single GenServer process adds serialisation overhead
  # and can become a bottleneck under load, with zero benefit over plain module
  # functions.

  @supported_currencies [:USD, :EUR, :GBP, :BRL, :JPY, :CAD, :AUD]

  @exchange_rates %{
    {:USD, :EUR} => 0.9201,
    {:USD, :GBP} => 0.7893,
    {:USD, :BRL} => 4.9732,
    {:USD, :JPY} => 149.87,
    {:USD, :CAD} => 1.3601,
    {:USD, :AUD} => 1.5312,
    {:EUR, :USD} => 1.0868,
    {:EUR, :GBP} => 0.8578,
    {:EUR, :BRL} => 5.4052,
    {:EUR, :JPY} => 162.88,
    {:EUR, :CAD} => 1.4782,
    {:EUR, :AUD} => 1.6641,
    {:GBP, :USD} => 1.2670,
    {:GBP, :EUR} => 1.1657,
    {:GBP, :BRL} => 6.3011,
    {:GBP, :JPY} => 189.87,
    {:GBP, :CAD} => 1.7230,
    {:GBP, :AUD} => 1.9395,
    {:BRL, :USD} => 0.2011,
    {:BRL, :EUR} => 0.1850,
    {:BRL, :GBP} => 0.1587,
    {:CAD, :USD} => 0.7352,
    {:AUD, :USD} => 0.6532,
    {:JPY, :USD} => 0.006672
  }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Converts `amount` from `from_currency` to `to_currency`.
  Returns `{:ok, converted_amount}` or `{:error, reason}`.
  """
  def convert(pid, amount, {from, to}) do
    GenServer.call(pid, {:convert, amount, from, to})
  end

  @doc """
  Returns the list of supported currency atoms.
  """
  def supported_currencies(pid) do
    GenServer.call(pid, :supported_currencies)
  end

  @doc """
  Returns the exchange rate between two currencies, or an error.
  """
  def exchange_rate(pid, from, to) do
    GenServer.call(pid, {:exchange_rate, from, to})
  end

  ## Server callbacks

  @impl true
  def init(:ok) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:convert, amount, from, to}, _from, state) when is_number(amount) do
    result =
      cond do
        from == to ->
          {:ok, Float.round(amount * 1.0, 4)}

        rate = Map.get(@exchange_rates, {from, to}) ->
          {:ok, Float.round(amount * rate, 4)}

        true ->
          {:error, :unsupported_currency_pair}
      end

    {:reply, result, state}
  end

  def handle_call({:convert, _amount, _from, _to}, _from, state) do
    {:reply, {:error, :invalid_amount}, state}
  end

  @impl true
  def handle_call(:supported_currencies, _from, state) do
    {:reply, @supported_currencies, state}
  end

  @impl true
  def handle_call({:exchange_rate, from, to}, _from, state) do
    result =
      case Map.get(@exchange_rates, {from, to}) do
        nil -> {:error, :unsupported_currency_pair}
        rate -> {:ok, rate}
      end

    {:reply, result, state}
  end

  # VALIDATION: SMELL END
end
```
