```elixir
defmodule Currency.Rate do
  @moduledoc false

  @type t :: %__MODULE__{
          base: String.t(),
          quote: String.t(),
          rate: float(),
          fetched_at: DateTime.t()
        }

  defstruct [:base, :quote, :rate, :fetched_at]
end

defmodule Currency.ExchangeRateService do
  @moduledoc """
  Maintains a cached set of exchange rates that refreshes on a configurable
  interval. Conversions are performed against the in-memory cache so they
  never block on a network call. A stale-rate guard rejects conversions
  when the cache has not been refreshed within the configured maximum age.
  """

  use GenServer

  require Logger

  alias Currency.Rate

  @type opts :: [
          refresh_interval_ms: pos_integer(),
          max_rate_age_ms: pos_integer(),
          fetcher: module()
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec convert(number(), String.t(), String.t()) ::
          {:ok, float()} | {:error, :no_rate | :stale_rates}
  def convert(amount, from_currency, to_currency)
      when is_binary(from_currency) and is_binary(to_currency) do
    GenServer.call(__MODULE__, {:convert, amount, String.upcase(from_currency), String.upcase(to_currency)})
  end

  @spec get_rate(String.t(), String.t()) ::
          {:ok, Rate.t()} | {:error, :no_rate}
  def get_rate(from, to) when is_binary(from) and is_binary(to) do
    GenServer.call(__MODULE__, {:get_rate, String.upcase(from), String.upcase(to)})
  end

  @spec force_refresh() :: :ok | {:error, term()}
  def force_refresh, do: GenServer.call(__MODULE__, :force_refresh)

  @impl GenServer
  def init(opts) do
    state = %{
      rates: %{},
      refresh_interval_ms: Keyword.get(opts, :refresh_interval_ms, 300_000),
      max_rate_age_ms: Keyword.get(opts, :max_rate_age_ms, 600_000),
      fetcher: Keyword.get(opts, :fetcher, Currency.HttpFetcher)
    }

    send(self(), :refresh)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:convert, amount, from, to}, _from, state) do
    reply =
      with :ok <- check_freshness(state),
           {:ok, rate} <- lookup_rate(state.rates, from, to) do
        {:ok, amount * rate.rate}
      end

    {:reply, reply, state}
  end

  def handle_call({:get_rate, from, to}, _from, state) do
    {:reply, lookup_rate(state.rates, from, to), state}
  end

  def handle_call(:force_refresh, _from, state) do
    {reply, new_state} = do_refresh(state)
    {:reply, reply, new_state}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    {_result, new_state} = do_refresh(state)
    Process.send_after(self(), :refresh, state.refresh_interval_ms)
    {:noreply, new_state}
  end

  defp do_refresh(state) do
    case state.fetcher.fetch_rates() do
      {:ok, rates} ->
        indexed = Map.new(rates, fn %Rate{base: b, quote: q} = r -> {{b, q}, r} end)
        Logger.debug("Exchange rates refreshed", count: map_size(indexed))
        {:ok, %{state | rates: indexed}}

      {:error, reason} ->
        Logger.warning("Exchange rate refresh failed", reason: inspect(reason))
        {{:error, reason}, state}
    end
  end

  defp lookup_rate(rates, from, to) do
    case Map.fetch(rates, {from, to}) do
      {:ok, rate} -> {:ok, rate}
      :error -> {:error, :no_rate}
    end
  end

  defp check_freshness(%{rates: rates}) when map_size(rates) == 0, do: {:error, :stale_rates}

  defp check_freshness(%{rates: rates, max_rate_age_ms: max_age}) do
    sample = rates |> Map.values() |> List.first()
    age_ms = DateTime.diff(DateTime.utc_now(), sample.fetched_at, :millisecond)
    if age_ms <= max_age, do: :ok, else: {:error, :stale_rates}
  end
end
```
