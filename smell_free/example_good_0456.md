```elixir
defmodule MyApp.Billing.TaxCalculator do
  @moduledoc """
  Computes applicable taxes for a transaction given the buyer's address
  and the product's tax category. Tax rules are loaded from the
  `tax_rules` table and keyed by `{country, region, tax_category}` in
  ETS for O(1) lookups at transaction time.

  Start this module under the application supervisor:

      children = [MyApp.Billing.TaxCalculator]
  """

  use GenServer

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Billing.TaxRule

  @table __MODULE__
  @reload_interval_ms 30 * 60 * 1_000

  @type address :: %{
          required(:country) => String.t(),
          optional(:region) => String.t()
        }

  @type tax_result :: %{
          applicable_rates: [%{name: String.t(), rate_bps: pos_integer()}],
          total_tax_bps: non_neg_integer(),
          tax_amount_cents: non_neg_integer()
        }

  @doc "Starts the tax calculator."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Computes taxes on `amount_cents` for a buyer at `address` purchasing
  a product in `tax_category`. Returns a structured tax result.
  """
  @spec calculate(pos_integer(), address(), String.t()) :: tax_result()
  def calculate(amount_cents, address, tax_category)
      when is_integer(amount_cents) and is_map(address) and is_binary(tax_category) do
    rates = applicable_rates(address, tax_category)
    total_bps = Enum.sum_by(rates, & &1.rate_bps)
    tax_cents = div(amount_cents * total_bps, 10_000)
    %{applicable_rates: rates, total_tax_bps: total_bps, tax_amount_cents: tax_cents}
  end

  @doc "Returns `true` when any tax applies to the given address and category."
  @spec taxable?(address(), String.t()) :: boolean()
  def taxable?(address, tax_category) do
    applicable_rates(address, tax_category) != []
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :bag, read_concurrency: true])
    load_rules()
    schedule_reload()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:reload, state) do
    :ets.delete_all_objects(@table)
    load_rules()
    schedule_reload()
    {:noreply, state}
  end

  @spec applicable_rates(address(), String.t()) :: [map()]
  defp applicable_rates(address, tax_category) do
    country = Map.fetch!(address, :country)
    region = Map.get(address, :region)

    keys = [
      {country, region, tax_category},
      {country, nil, tax_category},
      {country, region, "all"},
      {country, nil, "all"}
    ]

    keys
    |> Enum.flat_map(&:ets.lookup(@table, &1))
    |> Enum.map(fn {_key, name, rate_bps} -> %{name: name, rate_bps: rate_bps} end)
    |> Enum.uniq_by(& &1.name)
  end

  @spec load_rules() :: :ok
  defp load_rules do
    TaxRule
    |> where([r], r.active == true)
    |> Repo.all()
    |> Enum.each(fn rule ->
      :ets.insert(@table, {{rule.country, rule.region, rule.tax_category}, rule.name, rule.rate_bps})
    end)

    :ok
  end

  @spec schedule_reload() :: reference()
  defp schedule_reload, do: Process.send_after(self(), :reload, @reload_interval_ms)
end
```
