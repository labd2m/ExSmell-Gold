```elixir
defmodule MyApp.Scheduler.Registry do
  @moduledoc """
  DSL for declaring recurring background jobs and their scheduling configuration.

  Each `schedule/2` declaration registers a worker module with a cron expression,
  target queue, and execution constraints.

  ## Usage

      defmodule MyApp.Scheduler do
        use MyApp.Scheduler.Registry

        schedule MyApp.Jobs.DailyReportJob,
                 cron: "0 6 * * *", queue: :reporting, timeout_ms: 30_000

        schedule MyApp.Jobs.InvoiceReminderJob,
                 cron: "0 9 * * 1-5", queue: :billing, timeout_ms: 15_000, max_concurrency: 2

        schedule MyApp.Jobs.InventorySyncJob,
                 cron: "*/15 * * * *", queue: :logistics, timeout_ms: 60_000

        schedule MyApp.Jobs.SessionCleanupJob,
                 cron: "0 2 * * *", queue: :internal, timeout_ms: 10_000
      end
  """

  @valid_queues    [:billing, :reporting, :logistics, :identity, :payments, :internal, :default]
  @max_timeout_ms  300_000
  @max_concurrency 20

  defmacro __using__(_opts) do
    quote do
      import MyApp.Scheduler.Registry, only: [schedule: 2]
      Module.register_attribute(__MODULE__, :scheduled_jobs, accumulate: true)
      @before_compile MyApp.Scheduler.Registry
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc "Returns every registered job as a list of config maps."
      def all_jobs do
        Enum.map(@scheduled_jobs, fn {mod, cfg} ->
          Map.put(cfg, :worker, mod)
        end)
      end

      @doc "Returns the config map for the given worker module, or `nil`."
      def config_for(worker_module) do
        Enum.find_value(@scheduled_jobs, fn {mod, cfg} ->
          if mod == worker_module, do: Map.put(cfg, :worker, mod)
        end)
      end
    end
  end

  defmacro schedule(worker_module, opts) do
    quote do
      unless is_atom(unquote(worker_module)) do
        raise ArgumentError,
              "schedule/2: worker_module must be an atom (module), " <>
                "got: #{inspect(unquote(worker_module))}"
      end

      cron           = Keyword.fetch!(unquote(opts), :cron)
      queue          = Keyword.get(unquote(opts), :queue, :default)
      timeout_ms     = Keyword.get(unquote(opts), :timeout_ms, 30_000)
      max_concurrency = Keyword.get(unquote(opts), :max_concurrency, 1)

      unless is_binary(cron) and length(String.split(cron, " ")) == 5 do
        raise ArgumentError,
              "schedule/2: :cron must be a 5-field cron string (e.g. \"0 6 * * *\"), " <>
                "got: #{inspect(cron)}"
      end

      unless queue in unquote(@valid_queues) do
        raise ArgumentError,
              "schedule/2: unknown queue #{inspect(queue)}. " <>
                "Valid queues: #{inspect(unquote(@valid_queues))}"
      end

      unless is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= unquote(@max_timeout_ms) do
        raise ArgumentError,
              "schedule/2: :timeout_ms must be a positive integer <= #{unquote(@max_timeout_ms)}, " <>
                "got: #{inspect(timeout_ms)}"
      end

      unless is_integer(max_concurrency) and max_concurrency >= 1 and
               max_concurrency <= unquote(@max_concurrency) do
        raise ArgumentError,
              "schedule/2: :max_concurrency must be between 1 and #{unquote(@max_concurrency)}, " <>
                "got: #{inspect(max_concurrency)}"
      end

      job_cfg = %{cron: cron, queue: queue, timeout_ms: timeout_ms, max_concurrency: max_concurrency}

      @scheduled_jobs {unquote(worker_module), job_cfg}

      def unquote(:"job_#{worker_module}_cron")(), do: cron
      def unquote(:"job_#{worker_module}_queue")(), do: queue

      def unquote(:"job_#{worker_module}_config")() do
        %{
          worker:          unquote(worker_module),
          cron:            cron,
          queue:           queue,
          timeout_ms:      timeout_ms,
          max_concurrency: max_concurrency
        }
      end
    end
  end

  @doc "Returns the list of all recognised queue names."
  def valid_queues, do: @valid_queues
end
```
