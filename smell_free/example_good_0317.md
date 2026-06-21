```elixir
defmodule Observability.Metric do
  @moduledoc false

  @type kind :: :counter | :gauge | :histogram

  @type t :: %__MODULE__{
          name: String.t(),
          kind: kind(),
          help: String.t(),
          labels: [atom()],
          value: number() | map()
        }

  defstruct [:name, :kind, :help, :labels, value: 0]
end

defmodule Observability.Registry do
  @moduledoc """
  Stores metric definitions and accumulated values for Prometheus exposition.

  Metric registration is idempotent: registering the same name twice with
  the same kind is a no-op. Conflicting kinds raise to catch instrumentation
  mistakes at startup rather than silently producing corrupt output.
  """

  use GenServer

  alias Observability.Metric

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(String.t(), Metric.kind(), String.t(), [atom()]) :: :ok
  def register(name, kind, help, labels \\ [])
      when is_binary(name) and kind in [:counter, :gauge, :histogram] do
    GenServer.call(__MODULE__, {:register, name, kind, help, labels})
  end

  @spec increment(String.t(), number(), map()) :: :ok
  def increment(name, amount \\ 1, label_values \\ %{}) do
    GenServer.cast(__MODULE__, {:increment, name, amount, label_values})
  end

  @spec set(String.t(), number(), map()) :: :ok
  def set(name, value, label_values \\ %{}) do
    GenServer.cast(__MODULE__, {:set, name, value, label_values})
  end

  @spec all() :: [Metric.t()]
  def all, do: GenServer.call(__MODULE__, :all)

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:register, name, kind, help, labels}, _from, state) do
    case Map.get(state, name) do
      nil ->
        metric = %Metric{name: name, kind: kind, help: help, labels: labels}
        {:reply, :ok, Map.put(state, name, metric)}

      %Metric{kind: ^kind} ->
        {:reply, :ok, state}

      %Metric{kind: existing} ->
        raise "Metric #{name} already registered as #{existing}, cannot re-register as #{kind}"
    end
  end

  def handle_call(:all, _from, state) do
    {:reply, Map.values(state), state}
  end

  @impl GenServer
  def handle_cast({:increment, name, amount, labels}, state) do
    updated = update_in(state, [name, Access.key(:value)], &add_labeled(&1, labels, amount))
    {:noreply, updated}
  end

  def handle_cast({:set, name, value, labels}, state) do
    updated = update_in(state, [name, Access.key(:value)], &set_labeled(&1, labels, value))
    {:noreply, updated}
  end

  defp add_labeled(current, labels, amount) when is_number(current) and map_size(labels) == 0 do
    current + amount
  end

  defp add_labeled(current, labels, amount) when is_map(current) do
    Map.update(current, labels, amount, &(&1 + amount))
  end

  defp add_labeled(0, labels, amount) when map_size(labels) > 0, do: %{labels => amount}

  defp set_labeled(_current, labels, value) when map_size(labels) == 0, do: value
  defp set_labeled(current, labels, value) when is_map(current), do: Map.put(current, labels, value)
  defp set_labeled(_, labels, value), do: %{labels => value}
end

defmodule Observability.TextExposition do
  @moduledoc """
  Renders registered metrics to the Prometheus text exposition format.
  """

  alias Observability.{Metric, Registry}

  @spec render() :: iodata()
  def render do
    Registry.all()
    |> Enum.sort_by(& &1.name)
    |> Enum.map(&format_metric/1)
  end

  defp format_metric(%Metric{name: name, kind: kind, help: help, value: value}) do
    type_line = "# TYPE #{name} #{kind}\n"
    help_line = "# HELP #{name} #{help}\n"
    value_lines = format_value(name, value)
    [help_line, type_line, value_lines, "\n"]
  end

  defp format_value(name, value) when is_number(value), do: "#{name} #{value}\n"

  defp format_value(name, value) when is_map(value) do
    Enum.map(value, fn {labels, v} ->
      label_str = labels |> Enum.map_join(",", fn {k, v} -> "#{k}=\"#{v}\"" end)
      "#{name}{#{label_str}} #{v}\n"
    end)
  end
end
```
