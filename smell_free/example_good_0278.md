```elixir
defmodule MyApp.Search.IndexSynchronizer do
  @moduledoc """
  Keeps the Elasticsearch product index in sync with the Postgres catalog
  by processing `product_index_jobs` records. Each job represents a single
  document that needs to be indexed, re-indexed, or deleted. Jobs are
  claimed in batches using a SELECT FOR UPDATE SKIP LOCKED pattern so that
  multiple synchronizer instances can run in parallel without contention.

  Start one or more instances under the application supervisor:

      children = [
        {MyApp.Search.IndexSynchronizer, batch_size: 50, poll_interval_ms: 2_000}
      ]
  """

  use GenServer

  require Logger

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Search.{IndexJob, ESClient}

  @default_batch_size 50
  @default_poll_ms 2_000

  @type state :: %{
          batch_size: pos_integer(),
          poll_interval_ms: pos_integer()
        }

  @doc "Starts the index synchronizer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_ms)
    }

    schedule_poll(state.poll_interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    process_batch(state.batch_size)
    schedule_poll(state.poll_interval_ms)
    {:noreply, state}
  end

  @spec process_batch(pos_integer()) :: :ok
  defp process_batch(batch_size) do
    Repo.transaction(fn ->
      jobs = claim_jobs(batch_size)

      if jobs != [] do
        Logger.debug("index_sync_processing_batch", count: length(jobs))
        Enum.each(jobs, &execute_job/1)
        mark_complete(Enum.map(jobs, & &1.id))
      end
    end)

    :ok
  end

  @spec claim_jobs(pos_integer()) :: [IndexJob.t()]
  defp claim_jobs(batch_size) do
    IndexJob
    |> where([j], j.status == :pending)
    |> order_by([j], asc: j.inserted_at)
    |> limit(^batch_size)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
  end

  @spec execute_job(IndexJob.t()) :: :ok
  defp execute_job(%IndexJob{operation: :index, document_id: id, payload: payload}) do
    case ESClient.index_document(id, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("index_sync_index_failed", document_id: id, reason: inspect(reason))
    end
  end

  defp execute_job(%IndexJob{operation: :delete, document_id: id}) do
    case ESClient.delete_document(id) do
      :ok ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.warning("index_sync_delete_failed", document_id: id, reason: inspect(reason))
    end
  end

  @spec mark_complete([String.t()]) :: :ok
  defp mark_complete(ids) do
    Repo.update_all(
      from(j in IndexJob, where: j.id in ^ids),
      set: [status: :done, processed_at: DateTime.utc_now()]
    )

    :ok
  end

  @spec schedule_poll(pos_integer()) :: reference()
  defp schedule_poll(interval_ms),
    do: Process.send_after(self(), :poll, interval_ms)
end
```
