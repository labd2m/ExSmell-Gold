```elixir
defmodule Finance.CurrencyConverter do
  @moduledoc """
  A GenServer that fetches and caches foreign exchange rates, providing
  currency conversion with configurable staleness tolerance.

  Rates are refreshed automatically on a schedule. Conversions fall back
  to stale rates with a warning rather than failing hard, keeping the
  application operational during temporary rate provider outages.
  """

  use GenServer

  require Logger

  alias Finance.ExchangeRateProvider

  @type currency :: String.t()
  @type amount :: Decimal.t()
  @type rate :: Decimal.t()
  @type convert_result :: {:ok, amount()} | {:error, :unknown_currency | :no_rates_available}

  @refresh_interval_ms :timer.minutes(60)
  @stale_warning_after_ms :timer.hours(4)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Converts `amount` from `from_currency` to `to_currency`.
  Returns `{:ok, converted_amount}` or `{:error, reason}`.
  """
  @spec convert(amount(), currency(), currency()) :: convert_result()
  def convert(%Decimal{} = amount, from, to)
      when is_binary(from) and is_binary(to) do
    GenServer.call(__MODULE__, {:convert, amount, String.upcase(from), String.upcase(to)})
  end

  @doc "Returns the current exchange rate from `from_currency` to `to_currency`."
  @spec rate(currency(), currency()) :: {:ok, rate()} | {:error, :unknown_currency | :no_rates_available}
  def rate(from, to) when is_binary(from) and is_binary(to) do
    GenServer.call(__MODULE__, {:rate, String.upcase(from), String.upcase(to)})
  end

  @doc "Returns all currently cached rates keyed by currency code."
  @spec all_rates() :: %{optional(currency()) => rate()}
  def all_rates, do: GenServer.call(__MODULE__, :all_rates)

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :refresh_interval_ms, @refresh_interval_ms)
    send(self(), :refresh)
    {:ok, %{rates: %{}, refreshed_at: nil, interval: interval}}
  end

  @impl GenServer
  def handle_call({:convert, _amount, _from, _to}, _from, %{rates: rates} = state)
      when map_size(rates) == 0 do
    {:reply, {:error, :no_rates_available}, state}
  end

  def handle_call({:convert, amount, from, to}, _from, state) do
    warn_if_stale(state.refreshed_at)
    result = perform_conversion(amount, from, to, state.rates)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:rate, from, to}, _from, %{rates: rates} = state) do
    result = compute_rate(from, to, rates)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call(:all_rates, _from, state) do
    {:reply, state.rates, state}
  end

  @impl GenServer
  def handle_info(:refresh, %{interval: interval} = state) do
    new_state = fetch_and_update_rates(state)
    Process.send_after(self(), :refresh, interval)
    {:noreply, new_state}
  end

  defp perform_conversion(amount, from, to, rates) do
    with {:ok, rate} <- compute_rate(from, to, rates) do
      {:ok, Decimal.mult(amount, rate) |> Decimal.round(2)}
    end
  end

  defp compute_rate(same, same, _rates), do: {:ok, Decimal.new(1)}

  defp compute_rate(from, to, rates) do
    from_rate = Map.get(rates, from)
    to_rate = Map.get(rates, to)

    case {from_rate, to_rate} do
      {nil, _} -> {:error, :unknown_currency}
      {_, nil} -> {:error, :unknown_currency}
      {f, t} -> {:ok, Decimal.div(t, f)}
    end
  end

  defp fetch_and_update_rates(state) do
    case ExchangeRateProvider.fetch_rates() do
      {:ok, rates} ->
        Logger.info("[CurrencyConverter] Rates refreshed", count: map_size(rates))
        %{state | rates: rates, refreshed_at: DateTime.utc_now()}

      {:error, reason} ->
        Logger.error("[CurrencyConverter] Rate refresh failed", reason: inspect(reason))
        state
    end
  end

  defp warn_if_stale(nil), do: :ok

  defp warn_if_stale(refreshed_at) do
    age_ms = DateTime.diff(DateTime.utc_now(), refreshed_at, :millisecond)
    if age_ms > @stale_warning_after_ms do
      Logger.warning("[CurrencyConverter] Using stale rates", age_minutes: div(age_ms, 60_000))
    end
  end
end
```
