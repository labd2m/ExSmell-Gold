```elixir
defmodule NotificationQueue do
  @moduledoc """
  Routes notifications to the correct job queue based on priority
  and enforces retry policies per priority tier. Supports integration
  with an Oban-backed job processing system.
  """

  alias NotificationQueue.{Notification, Worker, DeadLetterStore}

  @type priority :: :critical | :high | :normal | :low

  @spec enqueue(Notification.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%Notification{} = notification) do
    queue = queue_name(notification.priority)
    attempts = max_attempts(notification.priority)

    %{
      notification_id: notification.id,
      channel: notification.channel,
      recipient_id: notification.recipient_id,
      payload: notification.payload
    }
    |> Worker.new(queue: queue, max_attempts: attempts)
    |> Oban.insert()
  end

  @spec enqueue_batch([Notification.t()]) :: {:ok, integer()} | {:error, term()}
  def enqueue_batch(notifications) when is_list(notifications) do
    results =
      Enum.map(notifications, fn notification ->
        {notification.id, enqueue(notification)}
      end)

    failures = Enum.filter(results, fn {_id, result} -> match?({:error, _}, result) end)

    if Enum.empty?(failures) do
      {:ok, length(notifications)}
    else
      {:error, {:partial_failure, Enum.map(failures, &elem(&1, 0))}}
    end
  end

  @spec handle_exhausted(map()) :: :ok
  def handle_exhausted(%{"notification_id" => notification_id} = job_args) do
    DeadLetterStore.record(notification_id, job_args)
  end





  @spec queue_name(priority()) :: String.t()
  def queue_name(priority) do
    case priority do
      :critical -> "notifications_critical"
      :high     -> "notifications_high"
      :normal   -> "notifications_normal"
      :low      -> "notifications_low"
    end
  end






  @spec max_attempts(priority()) :: integer()
  def max_attempts(priority) do
    case priority do
      :critical -> 10
      :high     -> 7
      :normal   -> 5
      :low      -> 3
    end
  end


  @spec drain_low_priority() :: {:ok, integer()}
  def drain_low_priority do
    {:ok, Oban.drain_queue(queue: queue_name(:low))}
  end

  @spec queue_depth(priority()) :: {:ok, integer()} | {:error, term()}
  def queue_depth(priority) do
    queue = queue_name(priority)

    case Oban.check_queue(queue: queue) do
      %{running: running, available: available} -> {:ok, running + available}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec all_queues() :: [String.t()]
  def all_queues do
    [:critical, :high, :normal, :low]
    |> Enum.map(&queue_name/1)
  end
end
```
