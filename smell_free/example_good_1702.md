```elixir
defmodule Finance.ExchangeRates do
  @moduledoc """
  Supervised GenServer that maintains a refreshed cache of currency exchange rates.

  Rates are fetched from a pluggable provider on startup and periodically
  refreshed. Conversion requests are served from the in-memory cache without
  performing I/O on the hot path.
  """

  use GenServer

  require Logger

  alias Finance.ExchangeRates.{Provider, RateTable, ConversionResult}

  @refresh_interval_ms 5 * 60 * 1_000

  @type currency :: String.t()

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Converts an amount from one currency to another using the cached rates.

  Returns `{:ok, result}` or `{:error, reason}` if either currency is unknown
  or the cache has not yet been populated.
  """
  @spec convert(pos_integer(), currency(), currency()) ::
          {:ok, ConversionResult.t()} | {:error, String.t()}
  def convert(amount_cents, from_currency, to_currency)
      when is_integer(amount_cents) and amount_cents > 0 and
             is_binary(from_currency) and is_binary(to_currency) do
    GenServer.call(__MODULE__, {:convert, amount_cents, from_currency, to_currency})
  end

  def convert(_, _, _), do: {:error, "invalid conversion arguments"}

  @doc """
  Returns the current exchange rate between two currencies.
  """
  @spec rate(currency(), currency()) :: {:ok, float()} | {:error, String.t()}
  def rate(from_currency, to_currency)
      when is_binary(from_currency) and is_binary(to_currency) do
    GenServer.call(__MODULE__, {:rate, from_currency, to_currency})
  end

  @doc """
  Forces an immediate rate refresh outside the normal refresh cycle.
  """
  @spec refresh() :: :ok | {:error, String.t()}
  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  @impl GenServer
  def init(opts) do
    provider = Keyword.get(opts, :provider, Provider.default())

    case fetch_rates(provider) do
      {:ok, table} ->
        schedule_refresh()
        {:ok, %{table: table, provider: provider}}

      {:error, reason} ->
        Logger.error("exchange rate initial load failed: #{reason}")
        schedule_refresh()
        {:ok, %{table: RateTable.empty(), provider: provider}}
    end
  end

  @impl GenServer
  def handle_call({:convert, amount_cents, from, to}, _from, %{table: table} = state) do
    reply = perform_conversion(table, amount_cents, from, to)
    {:reply, reply, state}
  end

  def handle_call({:rate, from, to}, _from, %{table: table} = state) do
    reply = RateTable.lookup_rate(table, from, to)
    {:reply, reply, state}
  end

  def handle_call(:refresh, _from, %{provider: provider} = state) do
    case fetch_rates(provider) do
      {:ok, table} -> {:reply, :ok, %{state | table: table}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info(:refresh, %{provider: provider} = state) do
    new_state =
      case fetch_rates(provider) do
        {:ok, table} ->
          Logger.debug("exchange rates refreshed")
          %{state | table: table}

        {:error, reason} ->
          Logger.warning("exchange rate refresh failed: #{reason}")
          state
      end

    schedule_refresh()
    {:noreply, new_state}
  end

  defp fetch_rates(provider) do
    case Provider.fetch_all(provider) do
      {:ok, rates} -> {:ok, RateTable.from_rates(rates)}
      error -> error
    end
  end

  defp perform_conversion(table, amount_cents, from, to) do
    with {:ok, rate} <- RateTable.lookup_rate(table, from, to) do
      converted = round(amount_cents * rate)
      {:ok, ConversionResult.new(amount_cents, from, converted, to, rate)}
    end
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval_ms)
end

defmodule Finance.ExchangeRates.RateTable do
  @moduledoc false

  @type t :: %{String.t() => %{String.t() => float()}}

  @spec empty() :: t()
  def empty, do: %{}

  @spec from_rates([%{from: String.t(), to: String.t(), rate: float()}]) :: t()
  def from_rates(rates) when is_list(rates) do
    Enum.reduce(rates, %{}, fn %{from: from, to: to, rate: r}, acc ->
      Map.update(acc, from, %{to => r}, &Map.put(&1, to, r))
    end)
  end

  @spec lookup_rate(t(), String.t(), String.t()) :: {:ok, float()} | {:error, String.t()}
  def lookup_rate(table, from, to) when from == to, do: {:ok, 1.0}

  def lookup_rate(table, from, to) do
    case get_in(table, [from, to]) do
      nil -> {:error, "no rate available for #{from} -> #{to}"}
      rate -> {:ok, rate}
    end
  end
end

defmodule Finance.ExchangeRates.ConversionResult do
  @moduledoc false

  @enforce_keys [:original_cents, :from_currency, :converted_cents, :to_currency, :rate]
  defstruct [:original_cents, :from_currency, :converted_cents, :to_currency, :rate]

  @type t :: %__MODULE__{
          original_cents: pos_integer(),
          from_currency: String.t(),
          converted_cents: integer(),
          to_currency: String.t(),
          rate: float()
        }

  @spec new(pos_integer(), String.t(), integer(), String.t(), float()) :: t()
  def new(orig, from, conv, to, rate) do
    %__MODULE__{
      original_cents: orig,
      from_currency: from,
      converted_cents: conv,
      to_currency: to,
      rate: rate
    }
  end
end

defmodule Finance.ExchangeRates.Provider do
  @moduledoc "Behaviour for exchange rate data providers."

  @callback fetch_all() :: {:ok, [map()]} | {:error, String.t()}

  @spec fetch_all(module()) :: {:ok, [map()]} | {:error, String.t()}
  def fetch_all(provider_module), do: provider_module.fetch_all()

  @spec default() :: module()
  def default, do: Application.get_env(:finance, :exchange_rate_provider, Finance.ExchangeRates.Providers.Stub)
end
```
