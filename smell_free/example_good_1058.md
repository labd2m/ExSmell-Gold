**File:** `example_good_1058.md`

```elixir
defmodule DataIngestion.WorkerSupervisor do
  @moduledoc """
  Manages a dynamically sized pool of ingestion workers.
  Each worker is started under supervision and linked to the supervisor,
  guaranteeing automatic restart on unexpected failures.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: 50)
  end

  @spec start_worker(map()) :: DynamicSupervisor.on_start_child()
  def start_worker(%{source_id: _} = config) do
    child_spec = {DataIngestion.Worker, config}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @spec stop_worker(pid()) :: :ok | {:error, :not_found}
  def stop_worker(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @spec active_workers() :: [pid()]
  def active_workers do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end
end

defmodule DataIngestion.Worker do
  @moduledoc """
  Stateful ingestion worker responsible for polling a single data source,
  applying transformation rules, and forwarding records downstream.
  """

  use GenServer, restart: :transient

  alias DataIngestion.{Pipeline, SourceConfig}

  @type state :: %{
          source_id: String.t(),
          config: SourceConfig.t(),
          last_cursor: term(),
          failure_count: non_neg_integer()
        }

  @poll_interval_ms 5_000
  @max_failures 5

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{source_id: source_id} = config) do
    GenServer.start_link(__MODULE__, config, name: via(source_id))
  end

  @spec pause(String.t()) :: :ok
  def pause(source_id) when is_binary(source_id) do
    GenServer.cast(via(source_id), :pause)
  end

  @spec resume(String.t()) :: :ok
  def resume(source_id) when is_binary(source_id) do
    GenServer.cast(via(source_id), :resume)
  end

  @impl GenServer
  def init(%{source_id: source_id} = config) do
    state = %{
      source_id: source_id,
      config: SourceConfig.build(config),
      last_cursor: nil,
      failure_count: 0,
      paused: false
    }

    schedule_poll()
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, %{paused: true} = state) do
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    case Pipeline.fetch_and_process(state.config, state.last_cursor) do
      {:ok, {records, next_cursor}} ->
        :ok = Pipeline.emit(records)
        schedule_poll()
        {:noreply, %{state | last_cursor: next_cursor, failure_count: 0}}

      {:error, _reason} when state.failure_count + 1 >= @max_failures ->
        {:stop, :too_many_failures, state}

      {:error, _reason} ->
        schedule_poll()
        {:noreply, %{state | failure_count: state.failure_count + 1}}
    end
  end

  @impl GenServer
  def handle_cast(:pause, state), do: {:noreply, %{state | paused: true}}
  def handle_cast(:resume, state), do: {:noreply, %{state | paused: false}}

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp via(source_id) do
    {:via, Registry, {DataIngestion.Registry, source_id}}
  end
end
```
