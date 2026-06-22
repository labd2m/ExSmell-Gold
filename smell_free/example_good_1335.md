```elixir
defmodule Events.Bus do
  @moduledoc """
  In-process event bus supporting typed subscriptions by event module.

  Subscribers register interest in specific event struct types. Published
  events are delivered to all matching subscribers asynchronously via
  supervised Tasks, isolating subscriber crashes from the bus process.
  """

  use GenServer

  alias Events.Bus.{Subscription, SubscriptionRegistry}

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Subscribes the calling process to events of the given struct type.

  Returns a subscription reference used for unsubscribing.
  """
  @spec subscribe(module(), keyword()) :: {:ok, reference()}
  def subscribe(event_module, opts \\ []) when is_atom(event_module) do
    filter_fn = Keyword.get(opts, :filter)
    GenServer.call(__MODULE__, {:subscribe, event_module, self(), filter_fn})
  end

  @doc """
  Cancels a previously registered subscription.
  """
  @spec unsubscribe(reference()) :: :ok
  def unsubscribe(ref) when is_reference(ref) do
    GenServer.cast(__MODULE__, {:unsubscribe, ref})
  end

  @doc """
  Publishes an event struct to all matching subscribers.
  """
  @spec publish(struct()) :: :ok
  def publish(%_{} = event) do
    GenServer.cast(__MODULE__, {:publish, event})
  end

  @doc """
  Returns the count of active subscriptions.
  """
  @spec subscription_count() :: non_neg_integer()
  def subscription_count do
    GenServer.call(__MODULE__, :subscription_count)
  end

  @impl GenServer
  def init(opts) do
    task_sup = Keyword.get(opts, :task_supervisor, Events.Bus.TaskSupervisor)
    {:ok, %{registry: SubscriptionRegistry.new(), task_sup: task_sup}}
  end

  @impl GenServer
  def handle_call({:subscribe, event_module, pid, filter_fn}, _from, state) do
    ref = make_ref()
    sub = Subscription.new(ref, event_module, pid, filter_fn)
    Process.monitor(pid)
    updated = SubscriptionRegistry.put(state.registry, sub)
    {:reply, {:ok, ref}, %{state | registry: updated}}
  end

  def handle_call(:subscription_count, _from, state) do
    {:reply, SubscriptionRegistry.count(state.registry), state}
  end

  @impl GenServer
  def handle_cast({:unsubscribe, ref}, state) do
    updated = SubscriptionRegistry.delete(state.registry, ref)
    {:noreply, %{state | registry: updated}}
  end

  def handle_cast({:publish, event}, %{registry: registry, task_sup: task_sup} = state) do
    event_module = event.__struct__

    registry
    |> SubscriptionRegistry.matching(event_module)
    |> Enum.filter(fn sub -> passes_filter?(sub, event) end)
    |> Enum.each(fn sub ->
      Task.Supervisor.start_child(task_sup, fn ->
        send(sub.pid, {:event, event})
      end)
    end)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    updated = SubscriptionRegistry.delete_by_pid(state.registry, pid)
    {:noreply, %{state | registry: updated}}
  end

  defp passes_filter?(%Subscription{filter_fn: nil}, _event), do: true
  defp passes_filter?(%Subscription{filter_fn: f}, event), do: f.(event)
end

defmodule Events.Bus.Subscription do
  @moduledoc false

  @enforce_keys [:ref, :event_module, :pid]
  defstruct [:ref, :event_module, :pid, :filter_fn]

  @type t :: %__MODULE__{
          ref: reference(),
          event_module: module(),
          pid: pid(),
          filter_fn: (struct() -> boolean()) | nil
        }

  @spec new(reference(), module(), pid(), (struct() -> boolean()) | nil) :: t()
  def new(ref, event_module, pid, filter_fn) do
    %__MODULE__{ref: ref, event_module: event_module, pid: pid, filter_fn: filter_fn}
  end
end

defmodule Events.Bus.SubscriptionRegistry do
  @moduledoc false

  alias Events.Bus.Subscription

  @type t :: %{reference() => Subscription.t()}

  @spec new() :: t()
  def new, do: %{}

  @spec put(t(), Subscription.t()) :: t()
  def put(registry, %Subscription{ref: ref} = sub), do: Map.put(registry, ref, sub)

  @spec delete(t(), reference()) :: t()
  def delete(registry, ref), do: Map.delete(registry, ref)

  @spec delete_by_pid(t(), pid()) :: t()
  def delete_by_pid(registry, pid) do
    Map.reject(registry, fn {_, sub} -> sub.pid == pid end)
  end

  @spec matching(t(), module()) :: [Subscription.t()]
  def matching(registry, event_module) do
    registry
    |> Map.values()
    |> Enum.filter(&(&1.event_module == event_module))
  end

  @spec count(t()) :: non_neg_integer()
  def count(registry), do: map_size(registry)
end
```
