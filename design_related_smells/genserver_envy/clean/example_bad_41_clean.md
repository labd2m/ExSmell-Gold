```elixir
defmodule NotificationWorker do
  @moduledoc """
  Sends notifications (email, SMS, push) on behalf of the notification
  pipeline and tracks delivery outcomes. Spawned per notification batch.
  """

  require Logger

  @max_retries 3
  @retry_delay_ms 2_000

  @type notification :: %{
          id: String.t(),
          channel: :email | :sms | :push,
          recipient: String.t(),
          payload: map()
        }

  @doc """
  Starts an async Task that sends a notification and keeps running,
  allowing the caller to poll for status updates.
  """
  def send_and_track(notification, caller_pid, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    Task.start(fn ->
      result = attempt_delivery(notification, 1)
      send(caller_pid, {:delivery_result, notification.id, result})

      message_loop(notification, result, caller_pid, timeout)
    end)
  end

  defp message_loop(notification, last_result, caller_pid, timeout) do
    receive do
      {:query_status, from_pid} ->
        send(from_pid, {:status_reply, notification.id, last_result})
        message_loop(notification, last_result, caller_pid, timeout)

      {:retry, from_pid} ->
        Logger.info("[NotificationWorker] Retrying notification #{notification.id}")
        new_result = attempt_delivery(notification, 1)
        send(from_pid, {:retry_result, notification.id, new_result})
        send(caller_pid, {:delivery_result, notification.id, new_result})
        message_loop(notification, new_result, caller_pid, timeout)

      :stop ->
        Logger.info("[NotificationWorker] Stopping worker for #{notification.id}")
        :ok
    after
      timeout ->
        Logger.warning("[NotificationWorker] Worker for #{notification.id} timed out")
        :timeout
    end
  end

  @doc "Sends a status query message to a running notification Task."
  def query_status(task_pid) do
    send(task_pid, {:query_status, self()})

    receive do
      {:status_reply, id, result} -> {:ok, id, result}
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Asks a running notification Task to retry the last failed delivery."
  def retry_failed(task_pid) do
    send(task_pid, {:retry, self()})

    receive do
      {:retry_result, id, result} -> {:ok, id, result}
    after
      10_000 -> {:error, :timeout}
    end
  end

  defp attempt_delivery(notification, attempt) when attempt > @max_retries do
    {:error, :max_retries_exceeded, notification.id}
  end

  defp attempt_delivery(notification, attempt) do
    Logger.info(
      "[NotificationWorker] Attempt #{attempt} for #{notification.channel} " <>
        "to #{notification.recipient}"
    )

    case dispatch(notification) do
      :ok ->
        Logger.info("[NotificationWorker] Delivered #{notification.id}")
        {:ok, :delivered, notification.id}

      {:error, reason} ->
        Logger.warning(
          "[NotificationWorker] Attempt #{attempt} failed: #{inspect(reason)}"
        )

        Process.sleep(@retry_delay_ms)
        attempt_delivery(notification, attempt + 1)
    end
  end

  defp dispatch(%{channel: :email, recipient: r, payload: p}) do
    # Simulated email dispatch
    if String.contains?(r, "@"), do: :ok, else: {:error, :invalid_email}
  end

  defp dispatch(%{channel: :sms, recipient: r, payload: _p}) do
    if String.match?(r, ~r/^\+\d{10,15}$/), do: :ok, else: {:error, :invalid_phone}
  end

  defp dispatch(%{channel: :push, payload: p}) do
    if Map.has_key?(p, :device_token), do: :ok, else: {:error, :missing_device_token}
  end
end
```
