```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes domain notifications to the appropriate delivery channels.
  Each channel (email, SMS, push, Slack) is implemented as an adapter
  module that satisfies the `Notifications.Channel` behaviour. Channel
  selection is driven by user notification preferences loaded from the
  database, so no dispatcher logic changes when channels are added or
  removed — only a new adapter and a preference row are needed.
  """

  alias Notifications.{Channel, Preferences, Template}

  require Logger

  @type notification :: %{
          required(:type) => binary(),
          required(:recipient_id) => binary(),
          required(:payload) => map()
        }

  @channel_adapters %{
    email: Notifications.Channels.Email,
    sms: Notifications.Channels.Sms,
    push: Notifications.Channels.Push,
    slack: Notifications.Channels.Slack
  }

  @doc """
  Dispatches `notification` to all channels enabled for the recipient.
  Returns a map of `{channel => result}` so callers can inspect per-channel
  outcomes without the entire dispatch failing on a single channel error.
  """
  @spec dispatch(notification()) :: %{atom() => :ok | {:error, term()}}
  def dispatch(%{recipient_id: recipient_id, type: type} = notification) do
    prefs = Preferences.for_user(recipient_id)
    enabled = active_channels(prefs, type)

    Logger.debug("Dispatching notification",
      type: type,
      recipient_id: recipient_id,
      channels: enabled
    )

    enabled
    |> Enum.map(fn channel ->
      adapter = Map.fetch!(@channel_adapters, channel)
      result = deliver(adapter, notification, channel)
      {channel, result}
    end)
    |> Map.new()
  end

  @doc """
  Returns the list of channel adapter modules currently registered.
  Useful for admin tooling that needs to enumerate supported channels.
  """
  @spec supported_channels() :: [atom()]
  def supported_channels, do: Map.keys(@channel_adapters)

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp active_channels(prefs, notification_type) do
    @channel_adapters
    |> Map.keys()
    |> Enum.filter(fn channel ->
      Preferences.channel_enabled?(prefs, channel, notification_type)
    end)
  end

  defp deliver(adapter, notification, channel) do
    with {:ok, template} <- Template.render(notification.type, channel, notification.payload),
         :ok <- adapter.send(notification.recipient_id, template) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Channel delivery failed",
          channel: channel,
          type: notification.type,
          recipient_id: notification.recipient_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end
end

defmodule Notifications.Channel do
  @moduledoc """
  Behaviour all notification channel adapters must implement.
  """

  @type recipient_id :: binary()
  @type rendered_template :: %{subject: binary() | nil, body: binary(), metadata: map()}

  @callback send(recipient_id(), rendered_template()) :: :ok | {:error, term()}
  @callback name() :: atom()
  @callback supports_rich_content?() :: boolean()
end

defmodule Notifications.Channels.Email do
  @moduledoc "Email channel adapter using Swoosh."
  @behaviour Notifications.Channel

  alias MyApp.{Emails, Mailer}

  @impl Notifications.Channel
  def name, do: :email

  @impl Notifications.Channel
  def supports_rich_content?, do: true

  @impl Notifications.Channel
  def send(recipient_id, %{subject: subject, body: body, metadata: meta}) do
    with {:ok, user} <- MyApp.Accounts.fetch_user(recipient_id) do
      Emails.generic(user.email, subject, body, meta)
      |> Mailer.deliver()
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:mailer_error, reason}}
      end
    end
  end
end

defmodule Notifications.Channels.Push do
  @moduledoc "Mobile push notification channel adapter."
  @behaviour Notifications.Channel

  @impl Notifications.Channel
  def name, do: :push

  @impl Notifications.Channel
  def supports_rich_content?, do: false

  @impl Notifications.Channel
  def send(recipient_id, %{subject: title, body: body}) do
    tokens = MyApp.Devices.push_tokens(recipient_id)

    results =
      Enum.map(tokens, fn token ->
        MyApp.PushClient.send(%{token: token, title: title, body: body})
      end)

    if Enum.any?(results, &match?(:ok, &1)), do: :ok, else: {:error, :all_tokens_failed}
  end
end
```
