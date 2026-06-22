# File: `example_good_742.md`

```elixir
defmodule Inventory.ReorderManager do
  @moduledoc """
  GenServer that monitors stock levels against per-SKU reorder points
  and triggers purchase order suggestions when stock falls below threshold.

  Reorder rules are configurable per SKU with individual reorder points,
  quantities, and supplier assignments. Suggestions are deduped within
  a cooldown window to prevent flooding the purchasing system after a
  single large depletion event.
  """

  use GenServer

  require Logger

  @default_poll_interval_ms 300_000
  @default_cooldown_ms 3_600_000

  @type sku :: String.t()
  @type quantity :: non_neg_integer()

  @type reorder_rule :: %{
          required(:sku) => sku(),
          required(:reorder_point) => quantity(),
          required(:reorder_quantity) => pos_integer(),
          required(:supplier_id) => String.t()
        }

  @type opts :: [
          stock_store: module(),
          handler: module(),
          poll_interval_ms: pos_integer(),
          cooldown_ms: pos_integer()
        ]

  @doc false
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers or replaces a reorder rule for a SKU.
  """
  @spec set_rule(reorder_rule()) :: :ok
  def set_rule(%{sku: sku} = rule) when is_binary(sku) do
    GenServer.cast(__MODULE__, {:set_rule, rule})
  end

  @doc """
  Removes the reorder rule for a SKU.
  """
  @spec remove_rule(sku()) :: :ok
  def remove_rule(sku) when is_binary(sku) do
    GenServer.cast(__MODULE__, {:remove_rule, sku})
  end

  @doc """
  Returns all registered reorder rules.
  """
  @spec rules() :: [reorder_rule()]
  def rules do
    GenServer.call(__MODULE__, :rules)
  end

  @doc """
  Returns SKUs currently in a suggestion cooldown period.
  """
  @spec cooling_down() :: [sku()]
  def cooling_down do
    GenServer.call(__MODULE__, :cooling_down)
  end

  @impl GenServer
  def init(opts) do
    stock_store = Keyword.fetch!(opts, :stock_store)
    handler = Keyword.fetch!(opts, :handler)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    cooldown_ms = Keyword.get(opts, :cooldown_ms, @default_cooldown_ms)

    schedule_poll(poll_interval_ms)

    {:ok, %{
      rules: %{},
      stock_store: stock_store,
      handler: handler,
      poll_interval_ms: poll_interval_ms,
      cooldown_ms: cooldown_ms,
      last_suggested: %{}
    }}
  end

  @impl GenServer
  def handle_cast({:set_rule, %{sku: sku} = rule}, state) do
    {:noreply, put_in(state, [:rules, sku], rule)}
  end

  @impl GenServer
  def handle_cast({:remove_rule, sku}, state) do
    {:noreply, update_in(state, [:rules], &Map.delete(&1, sku))}
  end

  @impl GenServer
  def handle_call(:rules, _from, state) do
    {:reply, Map.values(state.rules), state}
  end

  @impl GenServer
  def handle_call(:cooling_down, _from, state) do
    now = System.monotonic_time(:millisecond)
    cooling = Enum.flat_map(state.last_suggested, fn {sku, ts} ->
      if now - ts < state.cooldown_ms, do: [sku], else: []
    end)
    {:reply, cooling, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    new_state = run_check(state)
    schedule_poll(state.poll_interval_ms)
    {:noreply, new_state}
  end

  defp run_check(state) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(state.rules, state, fn {sku, rule}, acc ->
      in_cooldown = case Map.get(acc.last_suggested, sku) do
        nil -> false
        ts -> now - ts < acc.cooldown_ms
      end

      if in_cooldown do
        acc
      else
        check_and_suggest(acc, rule, now)
      end
    end)
  end

  defp check_and_suggest(state, rule, now) do
    case state.stock_store.level(rule.sku) do
      {:ok, level} when level <= rule.reorder_point ->
        Logger.info("Reorder suggested for #{rule.sku}: level=#{level}, point=#{rule.reorder_point}")
        suggestion = %{sku: rule.sku, quantity: rule.reorder_quantity, supplier_id: rule.supplier_id}

        case state.handler.suggest_purchase_order(suggestion) do
          :ok ->
            %{state | last_suggested: Map.put(state.last_suggested, rule.sku, now)}

          {:error, reason} ->
            Logger.warning("Reorder suggestion failed for #{rule.sku}: #{inspect(reason)}")
            state
        end

      {:ok, _level} ->
        state

      {:error, reason} ->
        Logger.warning("Could not fetch level for #{rule.sku}: #{inspect(reason)}")
        state
    end
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
```
