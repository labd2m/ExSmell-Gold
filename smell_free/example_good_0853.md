```elixir
defmodule Accounts.SessionCleanupJob do
  @moduledoc """
  Periodically removes expired session records from the database to
  prevent unbounded growth. Runs as a supervised GenServer on a
  configurable schedule, processing deletions in bounded batches to
  avoid long-running transactions on high-traffic deployments.
  Reports telemetry after each run for monitoring dashboards.
  """

  use GenServer

  require Logger

  alias MyApp.Repo
  alias Accounts.Session

  import Ecto.Query, warn: false

  @type run_summary :: %{deleted: non_neg_integer(), duration_ms: non_neg_integer()}

  @default_interval_ms :timer.minutes(30)
  @default_batch_size 500
  @telemetry_event [:accounts, :session_cleanup, :completed]

  @doc "Starts the session cleanup job."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Triggers an immediate cleanup run outside the schedule."
  @spec run_now() :: {:ok, run_summary()}
  def run_now, do: GenServer.call(__MODULE__, :run_now, :timer.minutes(5))

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    Process.send_after(self(), :run, interval)
    {:ok, %{interval: interval, batch_size: batch_size}}
  end

  @impl GenServer
  def handle_call(:run_now, _from, state) do
    summary = do_cleanup(state.batch_size)
    {:reply, {:ok, summary}, state}
  end

  @impl GenServer
  def handle_info(:run, %{interval: interval, batch_size: batch_size} = state) do
    summary = do_cleanup(batch_size)
    log_and_emit(summary)
    Process.send_after(self(), :run, interval)
    {:noreply, state}
  end

  defp do_cleanup(batch_size) do
    start_mono = System.monotonic_time(:millisecond)
    deleted = delete_expired_batched(batch_size, 0)
    duration_ms = System.monotonic_time(:millisecond) - start_mono
    %{deleted: deleted, duration_ms: duration_ms}
  end

  defp delete_expired_batched(batch_size, total_deleted) do
    now = DateTime.utc_now()

    ids =
      from(s in Session,
        where: s.expires_at < ^now,
        select: s.id,
        limit: ^batch_size
      )
      |> Repo.all()

    if Enum.empty?(ids) do
      total_deleted
    else
      {count, _} = Repo.delete_all(from(s in Session, where: s.id in ^ids))
      delete_expired_batched(batch_size, total_deleted + count)
    end
  end

  defp log_and_emit(%{deleted: 0}), do: :ok

  defp log_and_emit(%{deleted: deleted, duration_ms: ms}) do
    Logger.info("[SessionCleanup] Deleted #{deleted} expired session(s) in #{ms}ms")

    :telemetry.execute(@telemetry_event, %{deleted: deleted, duration_ms: ms}, %{})
  end
end
```
