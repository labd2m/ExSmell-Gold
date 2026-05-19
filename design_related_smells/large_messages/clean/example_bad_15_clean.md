```elixir
defmodule Risk.PriceSeries do
  defstruct [:ticker, :prices, :dates, :currency]
end

defmodule Risk.RiskFactor do
  defstruct [:factor_id, :name, :exposure, :beta, :scenario_shocks]
end

defmodule Risk.Position do
  @enforce_keys [:instrument_id, :ticker, :quantity, :cost_basis_cents]
  defstruct [
    :instrument_id,
    :ticker,
    :quantity,
    :cost_basis_cents,
    :current_price_cents,
    :market_value_cents,
    :asset_class,
    :sector,
    :geography,
    :risk_factors,
    :price_history
  ]
end

defmodule Risk.Portfolio do
  @enforce_keys [:id, :account_id, :positions]
  defstruct [
    :id,
    :account_id,
    :positions,
    :benchmark,
    :currency,
    :inception_date,
    :strategy,
    :constraints,
    :performance_history
  ]
end

defmodule Risk.PortfolioRepo do
  @moduledoc "Simulates loading a full portfolio with historical data."

  @spec load(String.t()) :: Risk.Portfolio.t()
  def load(portfolio_id) do
    %Risk.Portfolio{
      id: portfolio_id,
      account_id: "ACC-#{portfolio_id}",
      currency: "USD",
      inception_date: ~D[2020-01-01],
      strategy: "long_only_equity",
      benchmark: "SPX",
      constraints: %{
        max_single_position_pct: 5.0,
        min_cash_pct: 2.0,
        allowed_asset_classes: ["equity", "bond", "etf"]
      },
      positions: Enum.map(1..800, fn i ->
        %Risk.Position{
          instrument_id: "INST-#{i}",
          ticker: "TKR#{i}",
          quantity: Enum.random(100..10_000),
          cost_basis_cents: Enum.random(1_000..500_000),
          current_price_cents: Enum.random(1_000..600_000),
          market_value_cents: Enum.random(100_000..50_000_000),
          asset_class: Enum.random(["equity", "bond", "etf"]),
          sector: Enum.random(["tech", "finance", "health", "energy", "consumer"]),
          geography: Enum.random(["US", "EU", "LATAM", "APAC"]),
          risk_factors: Enum.map(1..5, fn j ->
            %Risk.RiskFactor{
              factor_id: "FACTOR-#{j}",
              name: "factor_#{j}",
              exposure: :rand.uniform(),
              beta: :rand.uniform() * 2 - 1,
              scenario_shocks: %{
                recession: -0.15 - :rand.uniform() * 0.2,
                rate_hike: -0.05 - :rand.uniform() * 0.1,
                market_rally: 0.1 + :rand.uniform() * 0.15
              }
            }
          end),
          price_history: %Risk.PriceSeries{
            ticker: "TKR#{i}",
            prices: Enum.map(1..252, fn _ -> :rand.uniform() * 500 + 10 end),
            dates: Enum.map(1..252, fn d -> Date.utc_today() |> Date.add(-d) end),
            currency: "USD"
          }
        }
      end),
      performance_history: Enum.map(1..60, fn m ->
        %{month: m, return_pct: :rand.uniform() * 0.1 - 0.05, benchmark_return_pct: :rand.uniform() * 0.08 - 0.04}
      end)
    }
  end
end

defmodule Risk.EvaluatorServer do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{evaluations: 0}, opts)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:evaluate, portfolio}, _from, state) do
    var =
      portfolio.positions
      |> Enum.map(fn pos -> pos.market_value_cents * 0.02 end)
      |> Enum.sum()

    result = %{portfolio_id: portfolio.id, value_at_risk_cents: round(var), evaluated_at: DateTime.utc_now()}
    {:reply, {:ok, result}, %{state | evaluations: state.evaluations + 1}}
  end
end

defmodule Risk.PortfolioEvaluator do
  @moduledoc "Client that submits portfolios to the risk evaluation server."

  require Logger

  @spec evaluate(pid(), String.t()) :: {:ok, map()} | {:error, term()}
  def evaluate(server_pid, portfolio_id) do
    Logger.info("Loading portfolio #{portfolio_id} for risk evaluation")

    portfolio = Risk.PortfolioRepo.load(portfolio_id)

    Logger.info(
      "Portfolio #{portfolio_id} loaded — #{length(portfolio.positions)} positions — submitting for evaluation"
    )

    result = GenServer.call(server_pid, {:evaluate, portfolio}, :infinity)

    result
  end
end
```
