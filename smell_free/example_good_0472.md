```elixir
defmodule ResourcePool do
  @moduledoc """
  A generic bounded resource pool supporting checkout with timeout and
  automatic idle resource reclamation.

  Resources are created on demand up to `max_size`. If all resources are
  checked out and a caller requests one, it waits up to `checkout_timeout_ms`.
  Resources idle for longer than `max_idle_ms` are closed and removed from
  the pool during the periodic sweep, preventing resource leaks.
  """

  use GenServer

  @type resource :: term()
  @type opts :: [
          name: atom(),
          max_size: pos_integer(),
          checkout_timeout_ms: pos_integer(),
          max_idle_ms: pos_integer(),
          create_fn: (-> {:ok, resource()} | {:error, term()}),
          close_fn: (resource() -> :ok)
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec checkout(atom(), pos_integer()) ::
          {:ok, resource()} | {:error, :timeout | :create_failed}
  def checkout(pool, timeout_ms \\ 5_000) when is_atom(pool) do
    GenServer.call(pool, :checkout, timeout_ms)
  rescue
    _ -> {:error, :timeout}
  end

  @spec checkin(atom(), resource()) :: :ok
  def checkin(pool, resource) when is_atom(pool) do
    GenServer.cast(pool, {:checkin, resource})
  end

  @spec stats(atom()) :: %{idle: non_neg_integer(), busy: non_neg_integer(), size: non_neg_integer()}
  def stats(pool), do: GenServer.call(pool, :stats)

  @impl GenServer
  def init(opts) do
    state = %{
      idle: [],
      busy: %{},
      waiters: :queue.new(),
      max_size: Keyword.get(opts, :max_size, 10),
      checkout_timeout_ms: Keyword.get(opts, :checkout_timeout_ms, 5_000),
      max_idle_ms: Keyword.get(opts, :max_idle_ms, 300_000),
      create_fn: Keyword.fetch!(opts, :create_fn),
      close_fn: Keyword.get(opts, :close_fn, fn _ -> :ok end)
    }

    Process.send_after(self(), :sweep_idle, state.max_idle_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:checkout, from, state) do
    case state.idle do
      [{resource, _ts} | rest] ->
        ref = make_ref()
        {:reply, {:ok, resource}, %{state | idle: rest, busy: Map.put(state.busy, ref, resource)}}

      [] when map_size(state.busy) < state.max_size ->
        case state.create_fn.() do
          {:ok, resource} ->
            ref = make_ref()
            {:reply, {:ok, resource}, %{state | busy: Map.put(state.busy, ref, resource)}}

          {:error, reason} ->
            {:reply, {:error, {:create_failed, reason}}, state}
        end

      [] ->
        timer = Process.send_after(self(), {:checkout_timeout, from}, state.checkout_timeout_ms)
        {:noreply, %{state | waiters: :queue.in({from, timer}, state.waiters)}}
    end
  end

  def handle_call(:stats, _from, state) do
    {:reply, %{idle: length(state.idle), busy: map_size(state.busy), size: length(state.idle) + map_size(state.busy)}, state}
  end

  @impl GenServer
  def handle_cast({:checkin, resource}, state) do
    case :queue.out(state.waiters) do
      {{:value, {waiter, timer}}, rest} ->
        Process.cancel_timer(timer)
        GenServer.reply(waiter, {:ok, resource})
        {:noreply, %{state | waiters: rest}}

      {:empty, _} ->
        {:noreply, %{state | idle: [{resource, System.monotonic_time(:millisecond)} | state.idle]}}
    end
  end

  @impl GenServer
  def handle_info({:checkout_timeout, from}, state) do
    GenServer.reply(from, {:error, :timeout})
    {:noreply, state}
  end

  def handle_info(:sweep_idle, state) do
    now = System.monotonic_time(:millisecond)

    {expired, kept} =
      Enum.split_with(state.idle, fn {_r, ts} -> now - ts > state.max_idle_ms end)

    Enum.each(expired, fn {resource, _} -> state.close_fn.(resource) end)
    Process.send_after(self(), :sweep_idle, state.max_idle_ms)
    {:noreply, %{state | idle: kept}}
  end
end
```
