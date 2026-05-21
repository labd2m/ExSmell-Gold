# Annotated Example 08 — Large Code Generation by Macros

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro defjob/2` inside `Scheduling.JobDSL`
- **Affected function(s):** `defjob/2`
- **Short explanation:** The macro expands a large quoted body—cron expression validation, queue name validation, concurrency limit checks, timeout bounds, retry policy validation, and module attribute registration—for each job declaration. Every call site causes all of this code to be re-expanded and compiled separately rather than being delegated to a plain function.

---

```elixir
defmodule Scheduling.JobDSL do
  @moduledoc """
  Compile-time DSL for declaring scheduled background jobs.

  Each job is bound to a cron expression, an Oban-style queue, and
  operational parameters such as concurrency limits, timeouts, and retry
  policies. All parameters are validated at compile time.
  """

  @valid_queues [:default, :critical, :bulk, :mailers, :reporting, :payments]

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because defjob/2 expands validations for
  # VALIDATION: cron syntax, queue, max_attempts, concurrency, timeout, and
  # VALIDATION: the overlap flag all inside the quoted block. Every one of
  # VALIDATION: the many job declarations causes the compiler to re-expand
  # VALIDATION: and compile this entire body, instead of calling a helper
  # VALIDATION: function that is compiled only once.
  defmacro defjob(job_name, opts) do
    quote do
      job  = unquote(job_name)
      opts = unquote(opts)

      unless is_atom(job) do
        raise ArgumentError,
              "job name must be an atom, got: #{inspect(job)}"
      end

      worker = Keyword.fetch!(opts, :worker)

      unless is_atom(worker) do
        raise ArgumentError,
              "job #{inspect(job)} :worker must be a module atom"
      end

      cron = Keyword.fetch!(opts, :cron)

      unless is_binary(cron) do
        raise ArgumentError,
              "job #{inspect(job)} :cron must be a cron expression string"
      end

      parts = String.split(cron, " ")

      unless length(parts) in [5, 6] do
        raise ArgumentError,
              "job #{inspect(job)} :cron '#{cron}' must have 5 or 6 space-separated fields"
      end

      queue = Keyword.get(opts, :queue, :default)

      unless queue in unquote(@valid_queues) do
        raise ArgumentError,
              "job #{inspect(job)} :queue must be one of #{inspect(unquote(@valid_queues))}"
      end

      max_attempts = Keyword.get(opts, :max_attempts, 3)

      unless is_integer(max_attempts) and max_attempts >= 1 do
        raise ArgumentError,
              "job #{inspect(job)} :max_attempts must be a positive integer"
      end

      concurrency = Keyword.get(opts, :concurrency, 1)

      unless is_integer(concurrency) and concurrency >= 1 do
        raise ArgumentError,
              "job #{inspect(job)} :concurrency must be a positive integer"
      end

      timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

      unless is_integer(timeout_ms) and timeout_ms >= 1_000 do
        raise ArgumentError,
              "job #{inspect(job)} :timeout_ms must be an integer >= 1_000"
      end

      allow_overlap = Keyword.get(opts, :allow_overlap, false)

      unless is_boolean(allow_overlap) do
        raise ArgumentError,
              "job #{inspect(job)} :allow_overlap must be a boolean"
      end

      @scheduled_jobs %{
        name:          job,
        worker:        worker,
        cron:          cron,
        queue:         queue,
        max_attempts:  max_attempts,
        concurrency:   concurrency,
        timeout_ms:    timeout_ms,
        allow_overlap: allow_overlap
      }
    end
  end
  # VALIDATION: SMELL END

  defmacro __using__(_) do
    quote do
      import Scheduling.JobDSL, only: [defjob: 2]
      Module.register_attribute(__MODULE__, :scheduled_jobs, accumulate: true)
      @before_compile Scheduling.JobDSL
    end
  end

  defmacro __before_compile__(env) do
    jobs = Module.get_attribute(env.module, :scheduled_jobs)

    quote do
      def jobs, do: unquote(Macro.escape(jobs))

      def job(name) do
        Enum.find(jobs(), &(&1.name == name))
      end

      def jobs_for_queue(queue) do
        Enum.filter(jobs(), &(&1.queue == queue))
      end
    end
  end
end

defmodule Scheduling.AppJobs do
  use Scheduling.JobDSL

  defjob(:daily_invoice_reminder,
    worker: Workers.InvoiceReminder,
    cron: "0 9 * * *",
    queue: :mailers,
    max_attempts: 5,
    concurrency: 2,
    timeout_ms: 60_000,
    allow_overlap: false
  )

  defjob(:weekly_revenue_report,
    worker: Workers.RevenueReport,
    cron: "0 6 * * 1",
    queue: :reporting,
    max_attempts: 3,
    concurrency: 1,
    timeout_ms: 120_000,
    allow_overlap: false
  )

  defjob(:hourly_payment_reconciliation,
    worker: Workers.PaymentReconciliation,
    cron: "0 * * * *",
    queue: :payments,
    max_attempts: 5,
    concurrency: 1,
    timeout_ms: 90_000,
    allow_overlap: false
  )

  defjob(:daily_inventory_snapshot,
    worker: Workers.InventorySnapshot,
    cron: "30 2 * * *",
    queue: :bulk,
    max_attempts: 2,
    concurrency: 1,
    timeout_ms: 300_000,
    allow_overlap: false
  )

  defjob(:every_5min_health_check,
    worker: Workers.HealthCheck,
    cron: "*/5 * * * *",
    queue: :critical,
    max_attempts: 1,
    concurrency: 1,
    timeout_ms: 5_000,
    allow_overlap: false
  )

  defjob(:monthly_subscription_renewal,
    worker: Workers.SubscriptionRenewal,
    cron: "0 4 1 * *",
    queue: :payments,
    max_attempts: 10,
    concurrency: 3,
    timeout_ms: 180_000,
    allow_overlap: false
  )

  defjob(:nightly_user_export,
    worker: Workers.UserDataExport,
    cron: "0 1 * * *",
    queue: :bulk,
    max_attempts: 2,
    concurrency: 1,
    timeout_ms: 600_000,
    allow_overlap: false
  )
end
```
