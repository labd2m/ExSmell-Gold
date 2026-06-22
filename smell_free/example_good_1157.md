```elixir
defmodule Notifications.Channel do
  @moduledoc "Behaviour contract for notification delivery channel implementations."

  alias Notifications.Notification

  @type delivery_result :: :ok | {:error, term()}

  @doc "Delivers a notification through the implementing transport."
  @callback deliver(Notification.t()) :: delivery_result()
end

defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes outbound notifications to the appropriate delivery channels
  based on each user's stored channel preferences.

  Channel modules implement the `Notifications.Channel` behaviour, ensuring
  a consistent delivery interface regardless of transport mechanism. The
  dispatcher is intentionally agnostic to transport details.
  """

  require Logger

  alias Notifications.{Channel, Preference, Notification}

  @channel_registry %{
    email: Notifications.Channels.Email,
    sms: Notifications.Channels.Sms,
    push: Notifications.Channels.Push,
    webhook: Notifications.Channels.Webhook
  }

  @type dispatch_result :: :ok | {:error, :no_channels_configured | term()}

  @doc """
  Dispatches `notification` to all channels enabled for the target user.

  Returns `:ok` when at least one channel accepts delivery. Returns
  `{:error, :no_channels_configured}` when the user has enabled no channels.
  """
  @spec dispatch(Notification.t()) :: dispatch_result()
  def dispatch(%Notification{} = notification) do
    notification.user_id
    |> Preference.enabled_channels_for()
    |> resolve_modules()
    |> deliver_to_all(notification)
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp resolve_modules([]), do: {:error, :no_channels_configured}

  defp resolve_modules(channel_names) do
    modules = Enum.flat_map(channel_names, &lookup_module/1)
    {:ok, modules}
  end

  defp lookup_module(name) do
    case Map.fetch(@channel_registry, name) do
      {:ok, module} -> [module]
      :error ->
        Logger.warning("Unknown notification channel", channel: name)
        []
    end
  end

  defp deliver_to_all({:error, _} = error, _notification), do: error

  defp deliver_to_all({:ok, []}, _notification), do: {:error, :no_channels_configured}

  defp deliver_to_all({:ok, modules}, notification) do
    modules
    |> Enum.map(&attempt_delivery(&1, notification))
    |> Enum.find(:ok, &match?({:error, _}, &1))
  end

  defp attempt_delivery(module, notification) do
    module.deliver(notification)
  rescue
    error ->
      Logger.error("Channel raised exception during delivery",
        module: inspect(module),
        reason: inspect(error)
      )
      {:error, {:channel_exception, module, error}}
  end
end

defmodule Notifications.Channels.Email do
  @moduledoc "Email delivery channel using the application mailer."
  @behaviour Notifications.Channel

  alias Notifications.{Notification, Mailer}

  @impl Notifications.Channel
  def deliver(%Notification{} = notification) do
    notification
    |> Mailer.build_email()
    |> Mailer.deliver()
  end
end

defmodule Notifications.Channels.Sms do
  @moduledoc "SMS delivery channel using the configured SMS provider."
  @behaviour Notifications.Channel

  alias Notifications.{Notification, SmsProvider}

  @impl Notifications.Channel
  def deliver(%Notification{} = notification) do
    SmsProvider.send_message(to: notification.phone_number, body: notification.body)
  end
end
```
