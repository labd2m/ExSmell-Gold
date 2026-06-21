```elixir
defmodule Platform.Semaphore do
  @moduledoc """
  A GenServer-based counting semaphore that limits concurrent access to a
  shared resource by a configurable number of holders.

  Unlike a mutex (which allows one holder), a semaphore allows up to `limit`
  concurrent permit holders. Callers that exceed the limit either block until
  a permit is available or receive `{:error, :no_permits}` immediately,
  depending on the `:mode` option.

  Permits are automatically reclaimed when a holder process exits.
  """

  use GenServer

  require Logger

  @type permit_ref :: reference()
  @type acquire_result :: {:ok, permit_ref()} | {:error, :no_permits | :timeout}
  @type mode :: :block | :reject

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Acquires a permit from the semaphore.

  In `:block` mode (default), the caller waits up to `timeout_ms` milliseconds
  for a permit. In `:reject` mode, returns `{:error, :no_permits}` immediately
  when all permits are held.
  """
  @spec acquire(GenServer.server(), keyword()) :: acquire_result()
  def acquire(server, opts \\ []) do
    mode = Keyword.get(opts, :mode, :block)
    timeout = Keyword.get(opts, :timeout_ms, 5_000)
    GenServer.call(server, {:acquire, self(), mode}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc "Releases a previously acquired permit."
  @spec release(GenServer.server(), permit_ref()) :: :ok | {:error, :invalid_permit}
  def release(server, permit_ref) when is_reference(permit_ref) do
    GenServer.call(server, {:release, permit_ref, self()})
  end

  @doc "Returns current semaphore utilization: `{active_permits, limit}`."
  @spec utilization(GenServer.server()) :: {non_neg_integer(), pos_integer()}
  def utilization(server), do: GenServer.call(server, :utilization)

  @impl GenServer
  def init(opts) do
    limit = Keyword.fetch!(opts, :limit)
    {:ok, %{limit: limit, permits: %{}, monitors: %{}, waiters: :queue.new()}}
  end

  @impl GenServer
  def handle_call({:acquire, caller, :reject}, _from, %{limit: limit, permits: permits} = state)
      when map_size(permits) >= limit do
    {:reply, {:error, :no_permits}, state}
  end

  def handle_call({:acquire, caller, _mode}, from, %{limit: limit, permits: permits} = state)
      when map_size(permits) >= limit do
    {:noreply, %{state | waiters: :queue.in({from, caller}, state.waiters)}}
  end

  def handle_call({:acquire, caller, _mode}, _from, state) do
    {permit_ref, new_state} = issue_permit(state, caller)
    {:reply, {:ok, permit_ref}, new_state}
  end

  @impl GenServer
  def handle_call({:release, permit_ref, caller}, _from, state) do
    case Map.get(state.permits, permit_ref) do
      %{holder: ^caller, monitor_ref: mref} ->
        Process.demonitor(mref, [:flush])
        {:reply, :ok, finalize_release(state, permit_ref, mref)}

      _ ->
        {:reply, {:error, :invalid_permit}, state}
    end
  end

  @impl GenServer
  def handle_call(:utilization, _from, %{permits: permits, limit: limit} = state) do
    {:reply, {map_size(permits), limit}, state}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    permit_ref = Enum.find_value(state.permits, fn {pref, %{monitor_ref: mref}} ->
      if mref == monitor_ref, do: pref
    end)

    new_state = if permit_ref, do: finalize_release(state, permit_ref, monitor_ref), else: state
    {:noreply, new_state}
  end

  defp issue_permit(state, caller) do
    permit_ref = make_ref()
    monitor_ref = Process.monitor(caller)
    entry = %{holder: caller, monitor_ref: monitor_ref}
    new_state = state
      |> put_in([:permits, permit_ref], entry)
      |> put_in([:monitors, monitor_ref], permit_ref)
    {permit_ref, new_state}
  end

  defp finalize_release(state, permit_ref, monitor_ref) do
    clean = state
      |> update_in([:permits], &Map.delete(&1, permit_ref))
      |> update_in([:monitors], &Map.delete(&1, monitor_ref))

    case :queue.out(clean.waiters) do
      {{:value, {from, caller}}, remaining} ->
        {new_ref, new_state} = issue_permit(%{clean | waiters: remaining}, caller)
        GenServer.reply(from, {:ok, new_ref})
        new_state

      {:empty, _} ->
        clean
    end
  end
end
```
