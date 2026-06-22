```elixir
defmodule Finance.ExchangeRateCache do
  @moduledoc """
  A supervised GenServer that caches foreign exchange rates fetched from
  a provider API. Rates are refreshed on a configurable interval and
  conversions are served entirely from memory to avoid blocking callers.
  """

  use GenServer

  alias Finance.{RateProvider, Money}

  @refresh_interval_ms 300_000
  @base_currency "USD"

  @type currency_code :: String.t()
  @type rate :: float()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec convert(Money.t(), currency_code()) :: {:ok, Money.t()} | {:error, :rate_unavailable}
  def convert(%Money{currency: from_currency} = money, to_currency)
      when is_binary(to_currency) do
    with {:ok, from_rate} <- get_rate(from_currency),
         {:ok, to_rate} <- get_rate(to_currency) do
      converted_amount = round(money.amount / from_rate * to_rate)
      {:ok, %Money{amount: converted_amount, currency: to_currency}}
    end
  end

  @spec get_rate(currency_code()) :: {:ok, rate()} | {:error, :rate_unavailable}
  def get_rate(currency) when is_binary(currency) do
    GenServer.call(__MODULE__, {:get_rate, String.upcase(currency)})
  end

  @spec all_rates() :: %{currency_code() => rate()}
  def all_rates do
    GenServer.call(__MODULE__, :all_rates)
  end

  @spec force_refresh() :: :ok | {:error, atom()}
  def force_refresh do
    GenServer.call(__MODULE__, :refresh, 15_000)
  end

  @impl GenServer
  def init(opts) do
    base = Keyword.get(opts, :base_currency, @base_currency)
    interval = Keyword.get(opts, :refresh_interval_ms, @refresh_interval_ms)

    state = %{rates: %{}, base_currency: base, refresh_interval: interval, last_updated: nil}

    case fetch_and_store_rates(state) do
      {:ok, new_state} ->
        schedule_refresh(interval)
        {:ok, new_state}

      {:error, _} ->
        schedule_refresh(interval)
        {:ok, state}
    end
  end

  @impl GenServer
  def handle_call({:get_rate, currency}, _from, state) do
    result = case Map.fetch(state.rates, currency) do
      {:ok, rate} -> {:ok, rate}
      :error -> {:error, :rate_unavailable}
    end
    {:reply, result, state}
  end

  def handle_call(:all_rates, _from, state) do
    {:reply, state.rates, state}
  end

  def handle_call(:refresh, _from, state) do
    case fetch_and_store_rates(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    new_state = case fetch_and_store_rates(state) do
      {:ok, updated} -> updated
      {:error, _} -> state
    end
    schedule_refresh(state.refresh_interval)
    {:noreply, new_state}
  end

  @spec fetch_and_store_rates(map()) :: {:ok, map()} | {:error, atom()}
  defp fetch_and_store_rates(state) do
    case RateProvider.fetch_rates(state.base_currency) do
      {:ok, rates} ->
        {:ok, %{state | rates: rates, last_updated: DateTime.utc_now()}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec schedule_refresh(pos_integer()) :: reference()
  defp schedule_refresh(interval), do: Process.send_after(self(), :refresh, interval)
end
```
