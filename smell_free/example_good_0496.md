```elixir
defmodule Platform.ReconciliationWorker do
  @moduledoc """
  A GenServer that periodically compares the application's database state
  against an external source of truth and surfaces discrepancies.

  Reconciliation runs are bounded by a configurable page size to avoid
  memory pressure. Detected discrepancies are logged and dispatched to a
  pluggable handler for resolution.
  """

  use GenServer

  require Logger

  @type discrepancy :: %{
          record_id: term(),
          field: atom(),
          local_value: term(),
          remote_value: term()
        }

  @type handler :: (discrepancy() -> :ok | {:error, term()})

  @default_interval_ms :timer.minutes(30)
  @default_page_size 200

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Triggers an immediate reconciliation run outside the normal schedule."
  @spec run_now(GenServer.server()) :: :ok
  def run_now(server \\ __MODULE__), do: GenServer.cast(server, :reconcile)

  @doc "Returns metadata about the most recent reconciliation run."
  @spec last_run_info(GenServer.server()) :: map() | nil
  def last_run_info(server \\ __MODULE__), do: GenServer.call(server, :last_run)

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    page_size = Keyword.get(opts, :page_size, @default_page_size)
    fetch_local = Keyword.fetch!(opts, :fetch_local_fn)
    fetch_remote = Keyword.fetch!(opts, :fetch_remote_fn)
    compare = Keyword.fetch!(opts, :compare_fn)
    handler = Keyword.get(opts, :handler_fn, &default_handler/1)

    schedule_reconcile(interval)

    {:ok, %{
      interval: interval,
      page_size: page_size,
      fetch_local: fetch_local,
      fetch_remote: fetch_remote,
      compare: compare,
      handler: handler,
      last_run: nil
    }}
  end

  @impl GenServer
  def handle_cast(:reconcile, state) do
    {:noreply, perform_reconciliation(state)}
  end

  @impl GenServer
  def handle_call(:last_run, _from, state) do
    {:reply, state.last_run, state}
  end

  @impl GenServer
  def handle_info(:reconcile, %{interval: interval} = state) do
    schedule_reconcile(interval)
    {:noreply, perform_reconciliation(state)}
  end

  defp perform_reconciliation(state) do
    started_at = DateTime.utc_now()
    Logger.info("[ReconciliationWorker] Starting reconciliation run")

    {checked, discrepancies} = run_pages(state)

    Enum.each(discrepancies, &state.handler.(&1))

    run_info = %{
      started_at: started_at,
      completed_at: DateTime.utc_now(),
      records_checked: checked,
      discrepancies_found: length(discrepancies)
    }

    Logger.info("[ReconciliationWorker] Run complete",
      checked: checked,
      discrepancies: length(discrepancies)
    )

    %{state | last_run: run_info}
  end

  defp run_pages(%{fetch_local: fetch_local, fetch_remote: fetch_remote, compare: compare, page_size: page_size}) do
    Stream.iterate(0, &(&1 + 1))
    |> Enum.reduce_while({0, []}, fn page, {count, acc} ->
      local_records = fetch_local.(page, page_size)

      if local_records == [] do
        {:halt, {count, acc}}
      else
        ids = Enum.map(local_records, & &1.id)
        remote_records = fetch_remote.(ids)
        remote_map = Map.new(remote_records, & {&1.id, &1})

        new_discrepancies = Enum.flat_map(local_records, &compare.(&1, Map.get(remote_map, &1.id)))
        {:cont, {count + length(local_records), acc ++ new_discrepancies}}
      end
    end)
  end

  defp default_handler(%{record_id: id, field: field, local_value: lv, remote_value: rv}) do
    Logger.warning("[ReconciliationWorker] Discrepancy detected",
      record_id: inspect(id),
      field: field,
      local: inspect(lv),
      remote: inspect(rv)
    )
    :ok
  end

  defp schedule_reconcile(interval), do: Process.send_after(self(), :reconcile, interval)
end
```
