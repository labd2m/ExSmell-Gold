```elixir
defmodule Observability.MetricsReporter do
  @moduledoc """
  Declares all application Telemetry metrics and wires them to a
  `TelemetryMetricsPrometheus` reporter. Metrics are grouped by subsystem
  so the Prometheus scrape endpoint exposes a consistent, well-labelled
  set of counters, summaries, and last-value gauges. New metrics are added
  here exclusively so there is always a single source of truth for what
  the application exposes.
  """

  import Telemetry.Metrics

  @doc """
  Returns the child spec for the Prometheus reporter. Add to the application
  supervisor to start exporting metrics on the configured port.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    port = Keyword.get(opts, :port, 9568)

    {TelemetryMetricsPrometheus,
     metrics: metrics(),
     port: port,
     name: __MODULE__}
  end

  @doc """
  Returns the full list of `Telemetry.Metrics` definitions for the application.
  """
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    http_metrics() ++
      database_metrics() ++
      oban_metrics() ++
      vm_metrics() ++
      business_metrics()
  end

  # ---------------------------------------------------------------------------
  # Metric groups
  # ---------------------------------------------------------------------------

  defp http_metrics do
    [
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route, :method, :status],
        unit: {:native, :millisecond},
        description: "HTTP request duration in milliseconds"
      ),
      counter("phoenix.router_dispatch.stop.count",
        tags: [:route, :method, :status],
        description: "Total HTTP requests handled"
      ),
      counter("phoenix.router_dispatch.exception.count",
        tags: [:route, :kind],
        description: "HTTP requests that raised an exception"
      )
    ]
  end

  defp database_metrics do
    [
      summary("my_app.repo.query.total_time",
        tags: [:source, :command],
        unit: {:native, :millisecond},
        description: "Ecto query total time"
      ),
      counter("my_app.repo.query.count",
        tags: [:source, :command],
        description: "Total Ecto queries executed"
      ),
      last_value("my_app.repo.pool.size",
        description: "Current DB connection pool size"
      ),
      last_value("my_app.repo.pool.checked_out",
        description: "DB connections currently checked out"
      )
    ]
  end

  defp oban_metrics do
    [
      counter("oban.job.stop.count",
        tags: [:queue, :worker, :state],
        description: "Oban jobs completed"
      ),
      summary("oban.job.stop.duration",
        tags: [:queue, :worker],
        unit: {:native, :millisecond},
        description: "Oban job execution duration"
      ),
      counter("oban.job.exception.count",
        tags: [:queue, :worker, :kind],
        description: "Oban jobs that raised exceptions"
      ),
      last_value("oban.queue.length",
        tags: [:queue],
        description: "Current number of jobs in each Oban queue"
      )
    ]
  end

  defp vm_metrics do
    [
      last_value("vm.memory.total",
        unit: :byte,
        description: "Total memory used by the BEAM"
      ),
      last_value("vm.total_run_queue_lengths.total",
        description: "Total run queue length across all schedulers"
      ),
      last_value("vm.total_run_queue_lengths.cpu",
        description: "CPU scheduler run queue length"
      ),
      summary("vm.msacc.process_time",
        description: "Time spent in process execution"
      )
    ]
  end

  defp business_metrics do
    [
      counter("my_app.orders.placed.count",
        tags: [:currency, :plan],
        description: "Orders successfully placed"
      ),
      summary("my_app.orders.total_cents",
        tags: [:currency],
        description: "Order total amounts in cents"
      ),
      counter("my_app.payments.charged.count",
        tags: [:currency, :gateway],
        description: "Payment charges successfully processed"
      ),
      counter("my_app.payments.failed.count",
        tags: [:currency, :gateway, :reason],
        description: "Payment charges that failed"
      ),
      last_value("my_app.subscriptions.active.count",
        tags: [:plan],
        description: "Currently active subscriptions by plan"
      )
    ]
  end
end
```
