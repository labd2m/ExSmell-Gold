# Annotated Example — Speculative Assumptions

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `Finance.ExchangeRates.get_rate/2`, around the map access with a default rate
- **Affected function(s):** `get_rate/2`
- **Short explanation:** The function looks up an exchange rate from a cached map using `Map.get/3` with `1.0` as the default. If the currency pair is not found in the cache (e.g., the rate feed was unavailable and the cache was never populated, or a new currency was added without updating the feed), the function silently returns `1.0` — as if the two currencies were at parity. Financial conversions proceed with the wrong rate, producing incorrect amounts that are indistinguishable from correct ones.

---

```elixir
defmodule Finance.ExchangeRates do
  @moduledoc """
  Provides real-time and cached exchange rates for multi-currency financial
  operations including invoice generation, reporting, and payment settlement.

  Rates are fetched from the central bank API every 15 minutes and cached
  in the process state. All rates are relative to BRL (Brazilian Real).
  """

  use GenServer

  require Logger

  @refresh_interval_ms 15 * 60 * 1000
  @rate_api_url        "https://api.bcb.gov.br/dados/serie/bcdata.sgs.10813/dados/ultimos/1?formato=json"

  @supported_currencies ~w(USD EUR GBP JPY ARS CLP COP MXN)

  defstruct rates: %{}, last_updated: nil, stale: true

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  def get_rate(from_currency, to_currency) do
    GenServer.call(__MODULE__, {:get_rate, from_currency, to_currency})
  end

  def convert(amount, from_currency, to_currency) do
    rate = get_rate(from_currency, to_currency)
    Float.round(amount * rate, 2)
  end

  def refresh_rates do
    GenServer.cast(__MODULE__, :refresh)
  end

  ## Server Callbacks

  def init(state) do
    schedule_refresh()
    {:ok, state, {:continue, :initial_load}}
  end

  def handle_continue(:initial_load, state) do
    {:noreply, do_refresh(state)}
  end

  def handle_cast(:refresh, state) do
    {:noreply, do_refresh(state)}
  end

  def handle_info(:refresh, state) do
    schedule_refresh()
    {:noreply, do_refresh(state)}
  end

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because the function uses Map.get/3 to look up
  # VALIDATION: the exchange rate with a default of 1.0. If the rate cache is empty
  # VALIDATION: (e.g., the initial fetch failed and no refresh has succeeded yet),
  # VALIDATION: or if a currency pair key like "USD_BRL" is missing (e.g., the API
  # VALIDATION: returned data in a different format and the cache was never populated
  # VALIDATION: for that pair), Map.get silently returns 1.0 — meaning "the currencies
  # VALIDATION: are at parity". All subsequent currency conversions use the wrong rate
  # VALIDATION: without any error, crash, or log warning. Invoices denominated in
  # VALIDATION: foreign currencies silently show wrong amounts, and the system appears
  # VALIDATION: to function correctly.
  def handle_call({:get_rate, from_currency, to_currency}, _from, state) do
    key  = "#{from_currency}_#{to_currency}"
    rate = Map.get(state.rates, key, 1.0)
    {:reply, rate, state}
  end
  # VALIDATION: SMELL END

  defp do_refresh(state) do
    case fetch_rates() do
      {:ok, rates} ->
        Logger.info("Exchange rates refreshed: #{map_size(rates)} pairs loaded")
        %{state | rates: rates, last_updated: DateTime.utc_now(), stale: false}

      {:error, reason} ->
        Logger.error("Failed to refresh exchange rates: #{inspect(reason)}")
        %{state | stale: true}
    end
  end

  defp fetch_rates do
    case :httpc.request(:get, {@rate_api_url |> String.to_charlist(), []}, [], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        body
        |> List.to_string()
        |> Jason.decode()
        |> case do
          {:ok, data} -> {:ok, build_rate_map(data)}
          error       -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_rate_map(data) do
    @supported_currencies
    |> Enum.flat_map(fn currency ->
      rate = extract_rate(data, currency)

      if rate do
        [
          {"#{currency}_BRL", rate},
          {"BRL_#{currency}", Float.round(1.0 / rate, 6)}
        ]
      else
        []
      end
    end)
    |> Map.new()
  end

  defp extract_rate(data, _currency) when is_list(data) do
    data |> List.last() |> Map.get("valor") |> parse_rate()
  end

  defp extract_rate(_, _), do: nil

  defp parse_rate(nil), do: nil
  defp parse_rate(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end
end
```
