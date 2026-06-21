```elixir
defmodule Events.DeadLetterQueue do
  @moduledoc """
  Captures events that failed all delivery attempts and stores them for
  operator inspection and manual replay. Dead-lettered events are
  persisted to the database with their failure reason and retry count.
  A bounded in-memory backlog protects against DB write bursts.
  """

  use GenServer

  require Logger

  alias MyApp.Repo
  alias Events.DeadLetter

  @type event_envelope :: map()
  @type failure_reason :: atom() | String.t()

  @flush_interval_ms 5_000
  @max_backlog 500

  @doc "Starts the dead letter queue server."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Enqueues a failed event envelope for dead-lettering."
  @spec enqueue(event_envelope(), failure_reason(), non_neg_integer()) :: :ok
  def enqueue(envelope, reason, attempt_count)
      when is_map(envelope) and is_integer(attempt_count) do
    GenServer.cast(__MODULE__, {:enqueue, envelope, reason, attempt_count})
  end

  @doc "Returns all stored dead-letter entries for manual inspection."
  @spec list_entries(keyword()) :: [DeadLetter.t()]
  def list_entries(opts \ []) do
    import Ecto.Query
    limit = Keyword.get(opts, :limit, 100)

    DeadLetter
    |> order_by([d], desc: d.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Replays a dead-lettered event by re-publishing its envelope."
  @spec replay(Ecto.UUID.t()) :: :ok | {:error, :not_found}
  def replay(dead_letter_id) when is_binary(dead_letter_id) do
    case Repo.get(DeadLetter, dead_letter_id) do
      nil ->
        {:error, :not_found}

      dead_letter ->
        Phoenix.PubSub.broadcast(MyApp.PubSub, "domain:events", {:domain_event, dead_letter.envelope})
        Repo.update!(DeadLetter.replayed_changeset(dead_letter))
        :ok
    end
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :flush_interval_ms, @flush_interval_ms)
    Process.send_after(self(), :flush, interval)
    {:ok, %{backlog: [], interval: interval}}
  end

  @impl GenServer
  def handle_cast({:enqueue, envelope, reason, attempts}, %{backlog: backlog} = state) do
    entry = %{envelope: envelope, failure_reason: to_string(reason), attempt_count: attempts}

    if length(backlog) >= @max_backlog do
      Logger.warning("[DeadLetterQueue] backlog full, dropping oldest entry")
      {:noreply, %{state | backlog: [entry | Enum.drop(backlog, -1)]}}
    else
      {:noreply, %{state | backlog: [entry | backlog]}}
    end
  end

  @impl GenServer
  def handle_info(:flush, %{backlog: [], interval: interval} = state) do
    Process.send_after(self(), :flush, interval)
    {:noreply, state}
  end

  def handle_info(:flush, %{backlog: backlog, interval: interval} = state) do
    flush_backlog(backlog)
    Process.send_after(self(), :flush, interval)
    {:noreply, %{state | backlog: []}}
  end

  defp flush_backlog(entries) do
    now = DateTime.utc_now()
    rows = Enum.map(entries, fn e -> Map.merge(e, %{inserted_at: now, updated_at: now}) end)
    Repo.insert_all(DeadLetter, rows)
    Logger.info("[DeadLetterQueue] flushed #{length(rows)} entry(ies)")
  rescue
    e -> Logger.error("[DeadLetterQueue] flush failed: #{Exception.message(e)}")
  end
end
```
