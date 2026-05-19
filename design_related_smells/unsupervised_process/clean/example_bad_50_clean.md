```elixir
defmodule Reporting.ReportScheduler do
  @moduledoc """
  Schedules and executes periodic report generation jobs for individual tenants.
  Each tenant's reporting configuration is maintained by a dedicated GenServer
  that wakes up on a configurable interval to generate, store, and distribute reports.
  """

  use GenServer

  alias Reporting.{
    ReportBuilder,
    StorageBackend,
    EmailDistributor,
    TenantConfig
  }

  @minimum_interval_minutes 5

  defstruct [
    :tenant_id,
    :report_type,
    :interval_minutes,
    :recipients,
    :last_run_at,
    :run_count,
    :timer_ref
  ]

  ## Public API

  @doc """
  Schedules a recurring report job for the given tenant.

  Options:
    - `:report_type`        - atom identifying the report (e.g. `:sales_summary`)
    - `:interval_minutes`   - how often to run (minimum #{@minimum_interval_minutes})
    - `:recipients`         - list of email addresses to deliver reports to
  """
 
  def schedule(tenant_id, opts \\ []) do
    report_type = Keyword.fetch!(opts, :report_type)
    interval_minutes = Keyword.get(opts, :interval_minutes, 60)
    recipients = Keyword.get(opts, :recipients, [])

    if interval_minutes < @minimum_interval_minutes do
      {:error, :interval_too_short}
    else
      GenServer.start(
        __MODULE__,
        %{
          tenant_id: tenant_id,
          report_type: report_type,
          interval_minutes: interval_minutes,
          recipients: recipients
        },
        name: worker_name(tenant_id, report_type)
      )
    end
  end

  @doc """
  Triggers an immediate (out-of-band) report run for a tenant.
  """
  def run_now(tenant_id, report_type) do
    GenServer.cast(worker_name(tenant_id, report_type), :run_now)
  catch
    :exit, _ -> {:error, :scheduler_not_running}
  end

  @doc """
  Returns metadata about the running scheduler for a tenant/report combo.
  """
  def info(tenant_id, report_type) do
    GenServer.call(worker_name(tenant_id, report_type), :info)
  catch
    :exit, _ -> {:error, :scheduler_not_running}
  end

  @doc """
  Cancels and shuts down the scheduler for a tenant.
  """
  def cancel(tenant_id, report_type) do
    GenServer.stop(worker_name(tenant_id, report_type), :normal)
  catch
    :exit, _ -> :ok
  end

  ## GenServer Callbacks

  @impl true
  def init(%{
        tenant_id: tenant_id,
        report_type: report_type,
        interval_minutes: interval_minutes,
        recipients: recipients
      }) do
    state = %__MODULE__{
      tenant_id: tenant_id,
      report_type: report_type,
      interval_minutes: interval_minutes,
      recipients: recipients,
      last_run_at: nil,
      run_count: 0,
      timer_ref: nil
    }

    {:ok, schedule_next(state)}
  end

  @impl true
  def handle_info(:run, state) do
    new_state = execute_report(state)
    {:noreply, schedule_next(new_state)}
  end

  @impl true
  def handle_cast(:run_now, state) do
    new_state = execute_report(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      tenant_id: state.tenant_id,
      report_type: state.report_type,
      interval_minutes: state.interval_minutes,
      last_run_at: state.last_run_at,
      run_count: state.run_count
    }

    {:reply, {:ok, info}, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    :ok
  end

  ## Private Helpers

  defp execute_report(state) do
    config = TenantConfig.fetch!(state.tenant_id)

    case ReportBuilder.build(state.report_type, config) do
      {:ok, report} ->
        {:ok, path} = StorageBackend.store(report, tenant_id: state.tenant_id)
        EmailDistributor.distribute(path, state.recipients, report_type: state.report_type)

        %{state | last_run_at: DateTime.utc_now(), run_count: state.run_count + 1}

      {:error, reason} ->
        :telemetry.execute(
          [:reporting, :scheduler, :failure],
          %{count: 1},
          %{tenant_id: state.tenant_id, report_type: state.report_type, reason: reason}
        )

        state
    end
  end

  defp schedule_next(state) do
    interval_ms = state.interval_minutes * 60 * 1_000
    timer_ref = Process.send_after(self(), :run, interval_ms)
    %{state | timer_ref: timer_ref}
  end

  defp worker_name(tenant_id, report_type) do
    {:via, Registry, {Reporting.SchedulerRegistry, {tenant_id, report_type}}}
  end
end
```
