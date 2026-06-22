```elixir
defmodule Comms.NotificationDigest do
  @moduledoc """
  Aggregates multiple notifications into a single periodic digest email.
  Notifications are buffered per user in-memory between digest flushes.
  The digest process fires on a configurable schedule and delivers one
  email per user who has buffered notifications, then clears the buffer.
  """

  use GenServer

  require Logger

  alias Notifications.Dispatcher, as: Notify

  @type user_id :: String.t()
  @type notification :: %{type: atom(), title: String.t(), body: String.t()}

  @flush_interval_ms :timer.minutes(60)

  @doc "Starts the digest aggregator."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Buffers a notification for inclusion in `user_id`'s next digest."
  @spec buffer(user_id(), notification()) :: :ok
  def buffer(user_id, %{type: _, title: _, body: _} = notification)
      when is_binary(user_id) do
    GenServer.cast(__MODULE__, {:buffer, user_id, notification})
  end

  @doc "Returns the count of buffered notifications for `user_id`."
  @spec pending_count(user_id()) :: non_neg_integer()
  def pending_count(user_id) when is_binary(user_id) do
    GenServer.call(__MODULE__, {:pending_count, user_id})
  end

  @doc "Forces an immediate digest flush for all users with buffered notifications."
  @spec flush_now() :: :ok
  def flush_now, do: GenServer.cast(__MODULE__, :flush)

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :flush_interval_ms, @flush_interval_ms)
    Process.send_after(self(), :flush, interval)
    {:ok, %{buffer: %{}, flush_interval: interval}}
  end

  @impl GenServer
  def handle_cast({:buffer, user_id, notification}, state) do
    new_buffer = Map.update(state.buffer, user_id, [notification], &[notification | &1])
    {:noreply, %{state | buffer: new_buffer}}
  end

  def handle_cast(:flush, state) do
    do_flush(state.buffer)
    {:noreply, %{state | buffer: %{}}}
  end

  @impl GenServer
  def handle_call({:pending_count, user_id}, _from, state) do
    count = state.buffer |> Map.get(user_id, []) |> length()
    {:reply, count, state}
  end

  @impl GenServer
  def handle_info(:flush, %{flush_interval: interval} = state) do
    do_flush(state.buffer)
    Process.send_after(self(), :flush, interval)
    {:noreply, %{state | buffer: %{}}}
  end

  defp do_flush(buffer) when map_size(buffer) == 0, do: :ok

  defp do_flush(buffer) do
    Logger.info("[NotificationDigest] Flushing digests for #{map_size(buffer)} user(s)")

    Enum.each(buffer, fn {user_id, notifications} ->
      items = Enum.reverse(notifications)

      Notify.dispatch(%{
        type: :notification_digest,
        recipient_id: user_id,
        payload: %{
          count: length(items),
          items: Enum.map(items, &Map.take(&1, [:type, :title, :body]))
        }
      })
    end)
  end
end
```
