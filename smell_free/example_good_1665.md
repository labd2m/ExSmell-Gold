```elixir
defmodule Rollout.Strategy do
  @moduledoc """
  Behaviour for progressive deployment rollout strategies.
  Strategies determine what percentage of traffic sees the new version.
  """

  @callback rollout_percentage(config :: map(), elapsed_minutes :: non_neg_integer()) :: float()
  @callback name() :: atom()
end

defmodule Rollout.Strategies.Linear do
  @behaviour Rollout.Strategy

  @moduledoc "Linearly increases rollout from 0% to 100% over a configured duration."

  @impl Rollout.Strategy
  def name, do: :linear

  @impl Rollout.Strategy
  def rollout_percentage(%{duration_minutes: duration}, elapsed) do
    min(elapsed / duration * 100.0, 100.0)
  end
end

defmodule Rollout.Strategies.Canary do
  @behaviour Rollout.Strategy

  @moduledoc "Holds at a small canary percentage before jumping to full rollout."

  @impl Rollout.Strategy
  def name, do: :canary

  @impl Rollout.Strategy
  def rollout_percentage(%{canary_pct: canary, bake_minutes: bake, full_pct: full}, elapsed) do
    if elapsed < bake, do: canary * 1.0, else: full * 1.0
  end
end

defmodule Rollout.Controller do
  use GenServer

  @moduledoc """
  Tracks active progressive deployments and answers routing queries.
  A deployment is resolved by its name; the controller evaluates the
  registered strategy to compute the current rollout percentage.
  """

  @type deployment :: %{
          name: String.t(),
          strategy_module: module(),
          strategy_config: map(),
          started_at: integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))
  end

  @spec register(String.t(), module(), map()) :: :ok
  def register(name, strategy_module, strategy_config)
      when is_binary(name) and is_atom(strategy_module) do
    deployment = %{
      name: name,
      strategy_module: strategy_module,
      strategy_config: strategy_config,
      started_at: System.monotonic_time(:second)
    }

    GenServer.cast(__MODULE__, {:register, deployment})
  end

  @spec current_percentage(String.t()) :: {:ok, float()} | {:error, :not_found}
  def current_percentage(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:percentage, name})
  end

  @spec route_to_new?(String.t(), String.t()) :: {:ok, boolean()} | {:error, :not_found}
  def route_to_new?(deployment_name, request_id) do
    with {:ok, pct} <- current_percentage(deployment_name) do
      bucket = request_bucket(request_id, deployment_name)
      {:ok, bucket <= pct}
    end
  end

  @spec deregister(String.t()) :: :ok
  def deregister(name) when is_binary(name) do
    GenServer.cast(__MODULE__, {:deregister, name})
  end

  @impl GenServer
  def init(:ok), do: {:ok, %{deployments: %{}}}

  @impl GenServer
  def handle_cast({:register, deployment}, state) do
    {:noreply, put_in(state.deployments[deployment.name], deployment)}
  end

  def handle_cast({:deregister, name}, state) do
    {:noreply, %{state | deployments: Map.delete(state.deployments, name)}}
  end

  @impl GenServer
  def handle_call({:percentage, name}, _from, state) do
    case Map.fetch(state.deployments, name) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, deployment} ->
        now = System.monotonic_time(:second)
        elapsed_minutes = div(now - deployment.started_at, 60)
        pct = deployment.strategy_module.rollout_percentage(deployment.strategy_config, elapsed_minutes)
        {:reply, {:ok, pct}, state}
    end
  end

  defp request_bucket(request_id, deployment_name) do
    hash_input = "#{deployment_name}:#{request_id}"
    <<first::32, _::binary>> = :crypto.hash(:md5, hash_input)
    rem(first, 100) + 1.0
  end
end
```
