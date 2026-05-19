# Code Smell Annotation

- **Smell name:** Unsupervised Process
- **Expected smell location:** `NotificationManager.deliver_async/2`
- **Affected function(s):** `deliver_async/2`
- **Short explanation:** The function uses `GenServer.start/3` to create a delivery worker for each notification batch. These processes are not supervised: they handle retries internally and can accumulate indefinitely (one per batch), with no supervisor able to restart failed workers or terminate stale ones during system shutdown.

---

```elixir
defmodule Notifications.NotificationManager do
  @moduledoc """
  Manages delivery of notification batches to users via multiple channels
  (email, push, SMS). Each batch is processed by a dedicated worker process
  responsible for per-channel dispatch, retries, and delivery receipts.
  """

  use GenServer

  alias Notifications.{
    EmailAdapter,
    PushAdapter,
    SMSAdapter,
    DeliveryLog,
    RateLimiter
  }

  @default_timeout_ms 15_000
  @retry_backoff_ms 5_000

  defstruct [
    :batch_id,
    :user_id,
    :channels,
    :payload,
    :attempts,
    :results
  ]

  ## Public API

  @doc """
  Enqueues a notification batch for asynchronous delivery.
  Spawns a worker process for the batch and returns immediately.

  Options:
    - `:channels` - list of channels to use, e.g. `[:email, :push]`
    - `:payload`  - map with `title`, `body`, and optional `data`
  """
  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because a new GenServer is started with
  # `GenServer.start/3` for every notification batch, completely outside
  # any supervision tree. If the delivery worker crashes mid-delivery
  # (e.g., adapter network timeout, unexpected payload format), the
  # process simply disappears with no restart strategy. In high-throughput
  # systems, hundreds of these orphaned processes can accumulate silently,
  # and there is no way to introspect or terminate them collectively.
  def deliver_async(user_id, opts \\ []) do
    batch_id = generate_batch_id()
    channels = Keyword.get(opts, :channels, [:email])
    payload = Keyword.fetch!(opts, :payload)

    {:ok, _pid} =
      GenServer.start(
        __MODULE__,
        %{
          batch_id: batch_id,
          user_id: user_id,
          channels: channels,
          payload: payload
        }
      )

    {:ok, batch_id}
  end
  # VALIDATION: SMELL END

  @doc """
  Synchronously delivers a notification to a single channel for a user.
  Returns `{:ok, receipt}` or `{:error, reason}`.
  """
  def deliver_sync(user_id, channel, payload) do
    dispatch_channel(channel, user_id, payload)
  end

  @doc """
  Retrieves the delivery log for a given batch.
  """
  def batch_status(batch_id) do
    DeliveryLog.get(batch_id)
  end

  ## GenServer Callbacks

  @impl true
  def init(%{batch_id: batch_id, user_id: user_id, channels: channels, payload: payload}) do
    state = %__MODULE__{
      batch_id: batch_id,
      user_id: user_id,
      channels: channels,
      payload: payload,
      attempts: 0,
      results: %{}
    }

    send(self(), :begin_delivery)
    {:ok, state}
  end

  @impl true
  def handle_info(:begin_delivery, state) do
    case RateLimiter.check(state.user_id) do
      :ok ->
        results = dispatch_all(state.channels, state.user_id, state.payload)
        DeliveryLog.record(state.batch_id, results)
        {:stop, :normal, %{state | results: results}}

      {:error, :rate_limited} ->
        Process.send_after(self(), :begin_delivery, @retry_backoff_ms)
        {:noreply, %{state | attempts: state.attempts + 1}}
    end
  end

  ## Private Helpers

  defp dispatch_all(channels, user_id, payload) do
    Task.async_stream(
      channels,
      fn channel -> {channel, dispatch_channel(channel, user_id, payload)} end,
      timeout: @default_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {channel, result}}, acc -> Map.put(acc, channel, result)
      {:exit, reason}, acc -> Map.put(acc, :unknown, {:error, reason})
    end)
  end

  defp dispatch_channel(:email, user_id, payload) do
    EmailAdapter.send(%{
      to: user_id,
      subject: payload.title,
      body: payload.body
    })
  end

  defp dispatch_channel(:push, user_id, payload) do
    PushAdapter.push(%{
      recipient: user_id,
      title: payload.title,
      body: payload.body,
      data: Map.get(payload, :data, %{})
    })
  end

  defp dispatch_channel(:sms, user_id, payload) do
    SMSAdapter.send(%{
      to: user_id,
      message: "#{payload.title}: #{payload.body}"
    })
  end

  defp dispatch_channel(channel, _user_id, _payload) do
    {:error, {:unknown_channel, channel}}
  end

  defp generate_batch_id do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end
end
```
