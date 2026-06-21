```elixir
defmodule MyAppWeb.NotificationChannel do
  @moduledoc """
  A Phoenix Channel that delivers real-time notifications to authenticated
  users. Each user joins their own private topic scoped to their user ID,
  preventing cross-user message leakage. Presence tracking records the
  number of active browser tabs per user so the application can skip
  push notifications when the user is already online.
  """

  use MyAppWeb, :channel

  alias MyAppWeb.{NotificationPresence, UserAuth}
  alias MyApp.{Notifications, Repo}

  require Logger

  @impl Phoenix.Channel
  def join("notifications:" <> user_id, _payload, socket) do
    with {:ok, current_user} <- UserAuth.load_user(socket),
         :ok <- assert_own_channel(current_user, user_id) do
      send(self(), :after_join)
      {:ok, assign(socket, :user_id, user_id)}
    else
      {:error, :unauthorized} ->
        {:error, %{reason: "unauthorized"}}

      {:error, :not_found} ->
        {:error, %{reason: "user_not_found"}}
    end
  end

  @impl Phoenix.Channel
  def handle_info(:after_join, socket) do
    {:ok, _} = NotificationPresence.track(socket, socket.assigns.user_id, %{
      online_at: DateTime.utc_now() |> DateTime.to_unix(),
      device: Map.get(socket.assigns, :device, "web")
    })

    push(socket, "presence_state", NotificationPresence.list(socket))

    unread_count = Notifications.unread_count(socket.assigns.user_id)
    push(socket, "unread_count", %{count: unread_count})

    {:noreply, socket}
  end

  @impl Phoenix.Channel
  def handle_in("mark_read", %{"notification_id" => notif_id}, socket)
      when is_binary(notif_id) do
    case Notifications.mark_read(notif_id, socket.assigns.user_id) do
      {:ok, _notification} ->
        unread_count = Notifications.unread_count(socket.assigns.user_id)
        {:reply, {:ok, %{unread_count: unread_count}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "notification_not_found"}}, socket}

      {:error, :unauthorized} ->
        {:reply, {:error, %{reason: "unauthorized"}}, socket}
    end
  end

  @impl Phoenix.Channel
  def handle_in("mark_all_read", _payload, socket) do
    {:ok, count} = Notifications.mark_all_read(socket.assigns.user_id)

    {:reply, {:ok, %{marked_read: count, unread_count: 0}}, socket}
  end

  @impl Phoenix.Channel
  def handle_in("fetch_notifications", %{"page" => page}, socket)
      when is_integer(page) and page > 0 do
    notifications =
      Notifications.list_for_user(socket.assigns.user_id, page: page, per_page: 20)
      |> Enum.map(&serialize_notification/1)

    {:reply, {:ok, %{notifications: notifications}}, socket}
  end

  @impl Phoenix.Channel
  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "unknown_event"}}, socket}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp assert_own_channel(%{id: user_id}, channel_user_id) when user_id == channel_user_id do
    :ok
  end

  defp assert_own_channel(_user, _channel_user_id), do: {:error, :unauthorized}

  defp serialize_notification(notification) do
    %{
      id: notification.id,
      type: notification.type,
      title: notification.title,
      body: notification.body,
      read: notification.read_at != nil,
      action_url: notification.action_url,
      inserted_at: DateTime.to_iso8601(notification.inserted_at)
    }
  end
end

defmodule MyAppWeb.NotificationPresence do
  @moduledoc """
  Tracks which users are currently connected to the notification channel.
  Used to suppress redundant push notifications when the user is online.
  """

  use Phoenix.Presence,
    otp_app: :my_app,
    pubsub_server: MyApp.PubSub

  @doc """
  Returns `true` when at least one session is active for `user_id`.
  """
  @spec online?(binary()) :: boolean()
  def online?(user_id) when is_binary(user_id) do
    "notifications:#{user_id}"
    |> list()
    |> map_size()
    |> Kernel.>(0)
  end
end
```
