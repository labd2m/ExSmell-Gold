```elixir
defmodule Finance.CurrencyConverter do
  @moduledoc """
  Converts monetary amounts between currencies using exchange rates stored
  in a GenServer cache. Rates are refreshed from an external provider at a
  configurable interval. Conversions use the cached mid-market rate. All
  arithmetic preserves cent-level precision using integer rounding.
  """

  use GenServer

  require Logger

  @type currency_code :: String.t()
  @type rate :: float()
  @type conversion_result ::
          {:ok, %{amount_cents: integer(), from: currency_code(), to: currency_code(), rate: rate()}}
          | {:error, :unknown_currency | :rate_unavailable}

  @refresh_interval_ms :timer.minutes(15)
  @base_currency "USD"

  @doc "Starts the currency converter with the given exchange rate provider."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Converts `amount_cents` from `from_currency` to `to_currency`. Returns
  the converted amount in cents using the current mid-market rate.
  """
  @spec convert(integer(), currency_code(), currency_code()) :: conversion_result()
  def convert(amount_cents, from_currency, to_currency)
      when is_integer(amount_cents) and is_binary(from_currency) and is_binary(to_currency) do
    GenServer.call(__MODULE__, {:convert, amount_cents, from_currency, to_currency})
  end

  @doc "Returns the current rate for converting `from` to `to`, or `{:error, :rate_unavailable}`."
  @spec rate(currency_code(), currency_code()) :: {:ok, rate()} | {:error, :rate_unavailable}
  def rate(from, to) when is_binary(from) and is_binary(to) do
    GenServer.call(__MODULE__, {:rate, from, to})
  end

  @doc "Forces an immediate rate refresh outside the scheduled interval."
  @spec refresh() :: :ok
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @impl GenServer
  def init(opts) do
    provider = Keyword.fetch!(opts, :provider)
    interval = Keyword.get(opts, :refresh_interval_ms, @refresh_interval_ms)
    rates = load_rates(provider)
    Process.send_after(self(), :refresh, interval)
    {:ok, %{rates: rates, provider: provider, interval: interval}}
  end

  @impl GenServer
  def handle_call({:convert, amount, from, to}, _from, state) do
    result =
      with {:ok, rate} <- lookup_cross_rate(state.rates, from, to) do
        converted = round(amount * rate)
        {:ok, %{amount_cents: converted, from: from, to: to, rate: rate}}
      end

    {:reply, result, state}
  end

  def handle_call({:rate, from, to}, _from, state) do
    {:reply, lookup_cross_rate(state.rates, from, to), state}
  end

  @impl GenServer
  def handle_cast(:refresh, state) do
    new_rates = load_rates(state.provider)
    {:noreply, %{state | rates: new_rates}}
  end

  @impl GenServer
  def handle_info(:refresh, %{interval: interval} = state) do
    new_rates = load_rates(state.provider)
    Process.send_after(self(), :refresh, interval)
    {:noreply, %{state | rates: new_rates}}
  end

  defp lookup_cross_rate(rates, from, to) when from == to, do: {:ok, 1.0}

  defp lookup_cross_rate(rates, from, to) do
    with {:ok, from_rate} <- Map.fetch(rates, from),
         {:ok, to_rate} <- Map.fetch(rates, to) do
      {:ok, to_rate / from_rate}
    else
      :error -> {:error, :rate_unavailable}
    end
  end

  defp load_rates(provider) do
    case provider.fetch_rates(@base_currency) do
      {:ok, rates} ->
        Logger.debug("[CurrencyConverter] Rates refreshed (#{map_size(rates)} currencies)")
        rates

      {:error, reason} ->
        Logger.warning("[CurrencyConverter] Rate refresh failed: #{inspect(reason)}")
        %{}
    end
  end
end
```
