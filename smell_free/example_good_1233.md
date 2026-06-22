```elixir
defmodule Feeds.Aggregator.FetchSupervisor do
  @moduledoc """
  Supervises a pool of feed fetcher workers, one per registered feed source.
  Workers are started dynamically and restarted on failure.
  """

  use Supervisor

  @doc """
  Starts the FetchSupervisor linked to the calling process.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a supervised fetcher for the given feed source specification.
  """
  @spec add_source(map()) :: DynamicSupervisor.on_start_child()
  def add_source(%{id: _id} = source) do
    child = Feeds.Aggregator.FetchWorker.child_spec(source: source)
    DynamicSupervisor.start_child(__MODULE__.Dynamic, child)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: __MODULE__.Dynamic, strategy: :one_for_one},
      {Registry, keys: :unique, name: Feeds.Registry}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Feeds.Aggregator.FetchWorker do
  @moduledoc """
  Periodically fetches a single RSS/Atom feed source and publishes
  new entries to the configured event bus. Runs as a supervised GenServer.
  """

  use GenServer

  @default_interval_ms 300_000

  @type source :: %{id: String.t(), url: String.t(), interval_ms: pos_integer()}

  @doc """
  Returns a child specification for this worker.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    source = Keyword.fetch!(opts, :source)

    %{
      id: {__MODULE__, source.id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc """
  Starts this worker linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    source = Keyword.fetch!(opts, :source)
    GenServer.start_link(__MODULE__, source, name: via(source.id))
  end

  @doc """
  Triggers an immediate fetch outside of the normal schedule.
  """
  @spec fetch_now(String.t()) :: :ok | {:error, :not_found}
  def fetch_now(source_id) when is_binary(source_id) do
    case Registry.lookup(Feeds.Registry, source_id) do
      [{pid, _}] ->
        GenServer.cast(pid, :fetch_now)
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @impl GenServer
  def init(source) do
    interval = Map.get(source, :interval_ms, @default_interval_ms)
    state = %{source: source, interval_ms: interval, last_fetched_at: nil}
    schedule_fetch(interval)
    {:ok, state}
  end

  @impl GenServer
  def handle_cast(:fetch_now, state) do
    new_state = run_fetch(state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:scheduled_fetch, state) do
    new_state = run_fetch(state)
    schedule_fetch(state.interval_ms)
    {:noreply, new_state}
  end

  defp run_fetch(state) do
    case Feeds.Http.Client.get(state.source.url) do
      {:ok, body} ->
        publish_entries(state.source.id, body)
        %{state | last_fetched_at: DateTime.utc_now()}

      {:error, reason} ->
        :telemetry.execute([:feeds, :fetch, :error], %{}, %{
          source_id: state.source.id,
          reason: reason
        })

        state
    end
  end

  defp publish_entries(source_id, body) do
    :telemetry.execute([:feeds, :fetch, :success], %{byte_size: byte_size(body)}, %{
      source_id: source_id
    })
  end

  defp schedule_fetch(interval), do: Process.send_after(self(), :scheduled_fetch, interval)
  defp via(id), do: {:via, Registry, {Feeds.Registry, id}}
end
```
