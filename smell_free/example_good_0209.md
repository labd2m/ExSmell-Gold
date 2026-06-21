# File: `example_good_209.md`

```elixir
defmodule Routing.WeightedBalancer do
  @moduledoc """
  GenServer implementing weighted round-robin load balancing across a
  dynamic set of named backends.

  Each backend is assigned a weight that determines the proportion of
  requests it receives relative to the total. Backends can be added,
  removed, and have their weights adjusted at runtime without dropping
  in-flight requests.
  """

  use GenServer

  @type backend_name :: String.t()
  @type weight :: pos_integer()

  @type backend :: %{
          required(:name) => backend_name(),
          required(:target) => term(),
          required(:weight) => weight()
        }

  @doc false
  def start_link(backends) when is_list(backends) do
    GenServer.start_link(__MODULE__, backends, name: __MODULE__)
  end

  @doc """
  Returns the next backend to route a request to, selected by weighted
  round-robin.

  Returns `{:ok, target}` or `{:error, :no_backends}` if the pool is empty.
  """
  @spec next() :: {:ok, term()} | {:error, :no_backends}
  def next do
    GenServer.call(__MODULE__, :next)
  end

  @doc """
  Registers a new backend or updates the weight of an existing one.
  """
  @spec register(backend_name(), term(), weight()) :: :ok
  def register(name, target, weight)
      when is_binary(name) and is_integer(weight) and weight > 0 do
    GenServer.cast(__MODULE__, {:register, name, target, weight})
  end

  @doc """
  Removes a backend from the pool. Future calls to `next/0` will not
  route to this backend.
  """
  @spec deregister(backend_name()) :: :ok
  def deregister(name) when is_binary(name) do
    GenServer.cast(__MODULE__, {:deregister, name})
  end

  @doc """
  Returns a snapshot of all registered backends and their weights.
  """
  @spec backends() :: [backend()]
  def backends do
    GenServer.call(__MODULE__, :backends)
  end

  @impl GenServer
  def init(backends) do
    expanded = expand_pool(backends)
    {:ok, %{backends: backends, pool: expanded, index: 0}}
  end

  @impl GenServer
  def handle_call(:next, _from, %{pool: []} = state) do
    {:reply, {:error, :no_backends}, state}
  end

  @impl GenServer
  def handle_call(:next, _from, state) do
    index = rem(state.index, length(state.pool))
    backend = Enum.at(state.pool, index)
    {:reply, {:ok, backend.target}, %{state | index: index + 1}}
  end

  @impl GenServer
  def handle_call(:backends, _from, state) do
    {:reply, state.backends, state}
  end

  @impl GenServer
  def handle_cast({:register, name, target, weight}, state) do
    existing = Enum.reject(state.backends, &(&1.name == name))
    new_backend = %{name: name, target: target, weight: weight}
    updated_backends = [new_backend | existing]
    {:noreply, %{state | backends: updated_backends, pool: expand_pool(updated_backends), index: 0}}
  end

  @impl GenServer
  def handle_cast({:deregister, name}, state) do
    updated_backends = Enum.reject(state.backends, &(&1.name == name))
    {:noreply, %{state | backends: updated_backends, pool: expand_pool(updated_backends), index: 0}}
  end

  defp expand_pool(backends) do
    Enum.flat_map(backends, fn backend ->
      List.duplicate(backend, backend.weight)
    end)
  end
end
```
