```elixir
defmodule Finance.CurrencyConverter do
  use GenServer

  @moduledoc """
  Provides currency conversion utilities for billing and invoicing workflows.
  Supports conversion between major currencies using static exchange rates.
  """

  @rates %{
    "USD" => 1.0,
    "EUR" => 0.92,
    "GBP" => 0.79,
    "JPY" => 149.50,
    "BRL" => 5.05,
    "CAD" => 1.36,
    "AUD" => 1.53,
    "CHF" => 0.90,
    "CNY" => 7.24,
    "MXN" => 17.15
  }



  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Converts `amount` from `from_currency` to `to_currency`.
  Returns `{:ok, converted_amount}` or `{:error, reason}`.
  """
  def convert(pid, amount, from_currency, to_currency) do
    GenServer.call(pid, {:convert, amount, from_currency, to_currency})
  end

  @doc """
  Returns the exchange rate between two currencies as `{:ok, rate}`.
  """
  def exchange_rate(pid, from_currency, to_currency) do
    GenServer.call(pid, {:exchange_rate, from_currency, to_currency})
  end

  @doc """
  Formats a monetary value with the appropriate currency symbol.
  """
  def format_amount(pid, amount, currency) do
    GenServer.call(pid, {:format_amount, amount, currency})
  end

  @doc """
  Returns the list of all supported currency codes.
  """
  def supported_currencies(pid) do
    GenServer.call(pid, :supported_currencies)
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:convert, amount, from, to}, _from, state) do
    result =
      with {:ok, from_rate} <- fetch_rate(from),
           {:ok, to_rate} <- fetch_rate(to) do
        usd_amount = amount / from_rate
        {:ok, Float.round(usd_amount * to_rate, 2)}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:exchange_rate, from, to}, _from, state) do
    result =
      with {:ok, from_rate} <- fetch_rate(from),
           {:ok, to_rate} <- fetch_rate(to) do
        {:ok, Float.round(to_rate / from_rate, 6)}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:format_amount, amount, currency}, _from, state) do
    symbol = currency_symbol(currency)
    value = :erlang.float_to_binary(amount / 1, [{:decimals, 2}])
    {:reply, "#{symbol}#{value}", state}
  end

  @impl true
  def handle_call(:supported_currencies, _from, state) do
    {:reply, Map.keys(@rates), state}
  end

  defp fetch_rate(currency) do
    case Map.get(@rates, currency) do
      nil -> {:error, "Unsupported currency: #{currency}"}
      rate -> {:ok, rate}
    end
  end

  defp currency_symbol("USD"), do: "$"
  defp currency_symbol("EUR"), do: "€"
  defp currency_symbol("GBP"), do: "£"
  defp currency_symbol("JPY"), do: "¥"
  defp currency_symbol("BRL"), do: "R$"
  defp currency_symbol("CAD"), do: "CA$"
  defp currency_symbol("AUD"), do: "A$"
  defp currency_symbol(other), do: "#{other} "
end
```
