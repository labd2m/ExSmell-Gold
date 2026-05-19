# Code Smell: Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `NotificationDispatcher.start/1`
- **Affected function(s):** `NotificationDispatcher.start/1`
- **Short explanation:** One `GenServer` is started per notification channel (email, SMS, push) using `GenServer.start/3` with no supervisor. If any dispatcher process crashes while delivering notifications, it is simply gone — no restart, no alerting, no recovery — silently dropping messages.

```elixir
defmodule NotificationDispatcher do
  use GenServer

  @moduledoc """
  Manages outbound notification delivery for a specific channel.
  Supports batching, retry logic, and delivery receipts.
  """

  @max_retries 3
  @retry_delay_ms 2_000

  defstruct [:channel, :config, pending: [], sent: [], failed: []]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because `GenServer.start/3` places the dispatcher
  # process outside any supervision tree. Notification dispatchers may run for the
  # entire lifetime of the application; if one crashes (e.g. due to a malformed
  # payload or a transient network error), it is lost permanently, and subsequent
  # calls to `dispatch/2` will raise because the named process no longer exists.
  def start(channel) when channel in [:email, :sms, :push] do
    config = load_channel_config(channel)
    GenServer.start(__MODULE__, %{channel: channel, config: config}, name: channel)
  end
  # VALIDATION: SMELL END

  def dispatch(channel, notification) do
    GenServer.cast(channel, {:enqueue, notification})
  end

  def flush(channel) do
    GenServer.call(channel, :flush)
  end

  def stats(channel) do
    GenServer.call(channel, :stats)
  end

  ## Callbacks

  @impl true
  def init(%{channel: channel, config: config}) do
    state = %__MODULE__{channel: channel, config: config}
    schedule_flush()
    {:ok, state}
  end

  @impl true
  def handle_cast({:enqueue, notification}, state) do
    {:noreply, %{state | pending: [notification | state.pending]}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {sent, failed} = attempt_delivery(state.pending, state.channel, state.config)

    new_state = %{state |
      pending: [],
      sent: sent ++ state.sent,
      failed: failed ++ state.failed
    }

    {:reply, {:ok, length(sent), length(failed)}, new_state}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      channel: state.channel,
      pending: length(state.pending),
      sent: length(state.sent),
      failed: length(state.failed)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:auto_flush, state) do
    {sent, failed} = attempt_delivery(state.pending, state.channel, state.config)

    new_state = %{state |
      pending: [],
      sent: sent ++ state.sent,
      failed: failed ++ state.failed
    }

    schedule_flush()
    {:noreply, new_state}
  end

  defp attempt_delivery(notifications, channel, config) do
    Enum.reduce(notifications, {[], []}, fn notif, {ok, err} ->
      case send_with_retry(notif, channel, config, @max_retries) do
        :ok -> {[notif | ok], err}
        {:error, _} -> {ok, [notif | err]}
      end
    end)
  end

  defp send_with_retry(_notif, _channel, _config, 0), do: {:error, :max_retries}
  defp send_with_retry(notif, channel, config, attempts) do
    case do_send(notif, channel, config) do
      :ok ->
        :ok
      {:error, _reason} ->
        Process.sleep(@retry_delay_ms)
        send_with_retry(notif, channel, config, attempts - 1)
    end
  end

  defp do_send(_notif, :email, _config), do: :ok
  defp do_send(_notif, :sms, _config), do: :ok
  defp do_send(_notif, :push, _config), do: :ok

  defp schedule_flush do
    Process.send_after(self(), :auto_flush, 5_000)
  end

  defp load_channel_config(:email), do: %{smtp_host: "smtp.example.com", port: 587}
  defp load_channel_config(:sms), do: %{api_url: "https://sms.example.com", key: "secret"}
  defp load_channel_config(:push), do: %{fcm_key: "fcm-key", apns_cert: "cert.pem"}
end

defmodule NotificationService do
  @moduledoc "Public API for sending notifications across all channels."

  def start_all_dispatchers do
    Enum.each([:email, :sms, :push], &NotificationDispatcher.start/1)
  end

  def send_notification(channel, to, body) do
    notification = %{to: to, body: body, sent_at: DateTime.utc_now()}
    NotificationDispatcher.dispatch(channel, notification)
  end
end
```
