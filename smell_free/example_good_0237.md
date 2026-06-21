# File: `example_good_237.md`

```elixir
defmodule Finance.CurrencyConverter do
  @moduledoc """
  GenServer that caches foreign exchange rates and performs currency
  conversions, refreshing its rate table on a configurable interval.

  Rates are fetched from a provider adapter supplied at startup, keeping
  this module decoupled from any specific exchange rate API. Stale rates
  are served during a refresh failure rather than blocking callers, and
  the staleness age is exposed for monitoring.
  """

  use GenServer

  require Logger

  @default_refresh_interval_ms 300_000

  @type currency :: String.t()
  @type rate :: float()
  @type rate_table :: %{currency() => rate()}

  @type convert_result ::
          {:ok, float()}
          | {:error, :unknown_currency}
          | {:error, :no_rates_available}

  @doc false
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Converts `amount` from `from_currency` to `to_currency`.

  All conversions are routed through the base currency stored in the
  rate table. Returns `{:ok, converted_amount}` rounded to two decimal
  places, or an error when a currency is unknown.
  """
  @spec convert(float(), currency(), currency()) :: convert_result()
  def convert(amount, from_currency, to_currency)
      when is_number(amount) and is_binary(from_currency) and is_binary(to_currency) do
    GenServer.call(__MODULE__, {:convert, amount, from_currency, to_currency})
  end

  @doc """
  Returns the current exchange rate from `from_currency` to `to_currency`.
  """
  @spec rate(currency(), currency()) :: {:ok, rate()} | {:error, atom()}
  def rate(from_currency, to_currency)
      when is_binary(from_currency) and is_binary(to_currency) do
    GenServer.call(__MODULE__, {:rate, from_currency, to_currency})
  end

  @doc """
  Returns the age of the current rate table in seconds.
  Returns `{:error, :no_rates_available}` if rates have never been loaded.
  """
  @spec rates_age_seconds() :: {:ok, non_neg_integer()} | {:error, :no_rates_available}
  def rates_age_seconds do
    GenServer.call(__MODULE__, :rates_age)
  end

  @impl GenServer
  def init(opts) do
    provider = Keyword.fetch!(opts, :provider)
    base_currency = Keyword.get(opts, :base_currency, "USD")
    refresh_ms = Keyword.get(opts, :refresh_interval_ms, @default_refresh_interval_ms)

    state = %{
      provider: provider,
      base_currency: base_currency,
      refresh_interval_ms: refresh_ms,
      rates: nil,
      rates_loaded_at: nil
    }

    send(self(), :refresh)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:convert, _amount, _from, _to}, _from, %{rates: nil} = state) do
    {:reply, {:error, :no_rates_available}, state}
  end

  @impl GenServer
  def handle_call({:convert, amount, from_curr, to_curr}, _from, state) do
    result = do_convert(state.rates, state.base_currency, amount, from_curr, to_curr)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:rate, _from, _to}, _from, %{rates: nil} = state) do
    {:reply, {:error, :no_rates_available}, state}
  end

  @impl GenServer
  def handle_call({:rate, from_curr, to_curr}, _from, state) do
    result = compute_cross_rate(state.rates, state.base_currency, from_curr, to_curr)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call(:rates_age, _from, %{rates_loaded_at: nil} = state) do
    {:reply, {:error, :no_rates_available}, state}
  end

  @impl GenServer
  def handle_call(:rates_age, _from, state) do
    age = System.system_time(:second) - state.rates_loaded_at
    {:reply, {:ok, age}, state}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    new_state = fetch_and_update_rates(state)
    schedule_refresh(state.refresh_interval_ms)
    {:noreply, new_state}
  end

  defp fetch_and_update_rates(state) do
    case state.provider.fetch_rates(state.base_currency) do
      {:ok, rates} ->
        %{state | rates: rates, rates_loaded_at: System.system_time(:second)}

      {:error, reason} ->
        Logger.warning("Exchange rate refresh failed: #{inspect(reason)}. Using stale rates.")
        state
    end
  end

  defp do_convert(rates, base, amount, from_curr, to_curr) do
    with {:ok, cross_rate} <- compute_cross_rate(rates, base, from_curr, to_curr) do
      {:ok, Float.round(amount * cross_rate, 2)}
    end
  end

  defp compute_cross_rate(rates, base, base, to_curr) do
    case Map.fetch(rates, to_curr) do
      {:ok, rate} -> {:ok, rate}
      :error -> {:error, :unknown_currency}
    end
  end

  defp compute_cross_rate(rates, base, from_curr, base) do
    case Map.fetch(rates, from_curr) do
      {:ok, rate} -> {:ok, 1.0 / rate}
      :error -> {:error, :unknown_currency}
    end
  end

  defp compute_cross_rate(rates, base, from_curr, to_curr) do
    with {:ok, from_rate} <- compute_cross_rate(rates, base, base, from_curr),
         {:ok, to_rate} <- compute_cross_rate(rates, base, base, to_curr) do
      {:ok, to_rate / from_rate}
    end
  end

  defp schedule_refresh(interval_ms) do
    Process.send_after(self(), :refresh, interval_ms)
  end
end
```
