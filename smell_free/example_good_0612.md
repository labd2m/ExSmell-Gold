# File: `example_good_612.md`

```elixir
defmodule Network.ServiceRegistry do
  @moduledoc """
  GenServer implementing a lightweight in-process service registry for
  dynamic service discovery within a single node.

  Services register themselves with a name, address, and metadata tags.
  Callers resolve services by name, optionally filtered by required tags.
  Stale registrations are evicted when the owning process exits.
  """

  use GenServer

  @type service_name :: String.t()
  @type address :: %{host: String.t(), port: :inet.port_number()}
  @type tag :: atom()

  @type service_entry :: %{
          name: service_name(),
          address: address(),
          tags: [tag()],
          pid: pid(),
          registered_at: DateTime.t()
        }

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Registers the calling process as a provider of `service_name`
  at the given `address` with optional metadata `tags`.

  When the calling process exits, the registration is automatically removed.
  Returns `:ok` or `{:error, :already_registered}` for the same pid.
  """
  @spec register(service_name(), address(), [tag()]) :: :ok | {:error, :already_registered}
  def register(service_name, %{host: _, port: _} = address, tags \\ [])
      when is_binary(service_name) do
    GenServer.call(__MODULE__, {:register, service_name, address, tags, self()})
  end

  @doc """
  Removes the calling process's registration for `service_name`.
  """
  @spec deregister(service_name()) :: :ok
  def deregister(service_name) when is_binary(service_name) do
    GenServer.cast(__MODULE__, {:deregister, service_name, self()})
  end

  @doc """
  Resolves all healthy registrations for `service_name`, optionally
  filtered to entries that carry all of `required_tags`.

  Returns an empty list when no matching registrations exist.
  """
  @spec resolve(service_name(), [tag()]) :: [service_entry()]
  def resolve(service_name, required_tags \\ []) when is_binary(service_name) do
    GenServer.call(__MODULE__, {:resolve, service_name, required_tags})
  end

  @doc """
  Returns one registration for `service_name` selected by round-robin,
  optionally filtered by tags.

  Returns `{:ok, entry}` or `{:error, :no_instances}`.
  """
  @spec resolve_one(service_name(), [tag()]) :: {:ok, service_entry()} | {:error, :no_instances}
  def resolve_one(service_name, required_tags \\ []) do
    GenServer.call(__MODULE__, {:resolve_one, service_name, required_tags})
  end

  @doc """
  Returns all registered service names currently in the registry.
  """
  @spec registered_services() :: [service_name()]
  def registered_services do
    GenServer.call(__MODULE__, :registered_services)
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{entries: [], counters: %{}}}

  @impl GenServer
  def handle_call({:register, name, address, tags, pid}, _from, state) do
    already = Enum.any?(state.entries, &(&1.pid == pid and &1.name == name))

    if already do
      {:reply, {:error, :already_registered}, state}
    else
      ref = Process.monitor(pid)
      entry = %{name: name, address: address, tags: tags, pid: pid,
                ref: ref, registered_at: DateTime.utc_now()}
      {:reply, :ok, %{state | entries: [entry | state.entries]}}
    end
  end

  @impl GenServer
  def handle_call({:resolve, name, required_tags}, _from, state) do
    matches = filter_entries(state.entries, name, required_tags)
    {:reply, Enum.map(matches, &entry_to_public/1), state}
  end

  @impl GenServer
  def handle_call({:resolve_one, name, required_tags}, _from, state) do
    matches = filter_entries(state.entries, name, required_tags)

    case matches do
      [] ->
        {:reply, {:error, :no_instances}, state}

      entries ->
        counter = Map.get(state.counters, name, 0)
        index = rem(counter, length(entries))
        selected = Enum.at(entries, index)
        new_state = put_in(state, [:counters, name], counter + 1)
        {:reply, {:ok, entry_to_public(selected)}, new_state}
    end
  end

  @impl GenServer
  def handle_call(:registered_services, _from, state) do
    names = state.entries |> Enum.map(& &1.name) |> Enum.uniq()
    {:reply, names, state}
  end

  @impl GenServer
  def handle_cast({:deregister, name, pid}, state) do
    {removed, remaining} = Enum.split_with(state.entries, &(&1.pid == pid and &1.name == name))
    Enum.each(removed, fn e -> Process.demonitor(e.ref, [:flush]) end)
    {:noreply, %{state | entries: remaining}}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    remaining = Enum.reject(state.entries, &(&1.ref == ref))
    {:noreply, %{state | entries: remaining}}
  end

  defp filter_entries(entries, name, required_tags) do
    Enum.filter(entries, fn e ->
      e.name == name and Enum.all?(required_tags, &(&1 in e.tags))
    end)
  end

  defp entry_to_public(entry) do
    Map.take(entry, [:name, :address, :tags, :pid, :registered_at])
  end
end
```
