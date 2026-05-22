```elixir
defmodule Scheduling.JobRunner do
  @moduledoc """
  Manages the enqueueing of recurring background jobs. All scheduled times
  are expressed in the configured application timezone and then converted to
  UTC before being persisted to the job queue.
  """

  require Logger

  @schedule_timezone Application.fetch_env!(:scheduling, :timezone)

  @supported_frequencies ~w(daily weekly monthly)
  @job_queue_name "background_jobs"
  @max_jitter_seconds 300

  @type job_spec :: %{
          name: String.t(),
          module: module(),
          args: map(),
          frequency: String.t()
        }

  @doc """
  Enqueues a daily report generation job. The job is scheduled to run at
  the given `hour` (0–23) in the configured timezone.

  ## Parameters
    - `spec` - A `job_spec` map describing the report job.
    - `hour` - The hour of day (in `#{@schedule_timezone}`) to run the job.
  """
  @spec enqueue_daily_report(job_spec(), 0..23) :: {:ok, String.t()} | {:error, term()}
  def enqueue_daily_report(spec, hour \\ 6) when hour in 0..23 do
    run_at = next_run_at({:daily, hour})
    Logger.info("Enqueueing daily report job=#{spec.name} next_run_at=#{run_at}")
    push_job(spec, run_at)
  end

  @doc """
  Enqueues a billing-cycle job that should run on the first day of each month.

  ## Parameters
    - `spec` - A `job_spec` map describing the billing job.
  """
  @spec enqueue_billing_cycle(job_spec()) :: {:ok, String.t()} | {:error, term()}
  def enqueue_billing_cycle(spec) do
    run_at = next_run_at(:monthly_first)
    Logger.info("Enqueueing billing-cycle job=#{spec.name} next_run_at=#{run_at}")
    push_job(spec, run_at)
  end

  @doc """
  Calculates the next UTC `DateTime` at which a job should run given its
  recurrence descriptor. Applies a small random jitter to avoid thundering herds.

  ## Parameters
    - `descriptor` - One of `{:daily, hour}`, `:monthly_first`, or `:weekly`.
  """
  @spec next_run_at(term()) :: DateTime.t()
  def next_run_at(descriptor) do
    base_utc = compute_base_utc(descriptor)
    jitter = :rand.uniform(@max_jitter_seconds)
    DateTime.add(base_utc, jitter, :second)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp push_job(%{name: name, module: mod, args: args}, run_at) do
    job = %{
      id: UUID.uuid4(),
      name: name,
      module: to_string(mod),
      args: args,
      scheduled_at: DateTime.to_iso8601(run_at),
      queue: @job_queue_name
    }

    case Scheduling.QueueAdapter.enqueue(job) do
      {:ok, job_id} ->
        Logger.info("Job enqueued job_id=#{job_id} name=#{name}")
        {:ok, job_id}

      {:error, reason} ->
        Logger.error("Failed to enqueue job name=#{name} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp compute_base_utc({:daily, hour}) do
    now_local = DateTime.now!(@schedule_timezone)
    today = DateTime.to_date(now_local)
    candidate = local_datetime_to_utc(today, hour)
    if DateTime.compare(candidate, now_local) == :gt, do: candidate, else: DateTime.add(candidate, 86_400, :second)
  end

  defp compute_base_utc(:monthly_first) do
    now_local = DateTime.now!(@schedule_timezone)
    today = DateTime.to_date(now_local)
    first_of_next = %{today | day: 1} |> Date.add(Date.days_in_month(today))
    local_datetime_to_utc(first_of_next, 0)
  end

  defp compute_base_utc(:weekly) do
    now_local = DateTime.now!(@schedule_timezone)
    days_until_monday = Integer.mod(8 - Date.day_of_week(DateTime.to_date(now_local)), 7)
    local_datetime_to_utc(Date.add(DateTime.to_date(now_local), days_until_monday), 0)
  end

  defp local_datetime_to_utc(date, hour) do
    {:ok, naive} = NaiveDateTime.new(date, Time.new!(hour, 0, 0))
    DateTime.from_naive!(naive, @schedule_timezone) |> DateTime.shift_zone!("Etc/UTC")
  end

  defp validate_frequency!(freq) when freq in @supported_frequencies, do: freq
  defp validate_frequency!(freq), do: raise ArgumentError, "Unsupported frequency: #{freq}"
end
```
