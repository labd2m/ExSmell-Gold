**File:** `example_good_1067.md`

```elixir
defmodule Notifications.Channel do
  @moduledoc """
  Behaviour contract for notification delivery channels.
  Each channel adapter must implement `deliver/2` and `supports?/1`.
  """

  @type notification :: %{
          recipient_id: String.t(),
          template: atom(),
          variables: map()
        }

  @type delivery_result :: :ok | {:error, term()}

  @callback deliver(notification(), keyword()) :: delivery_result()
  @callback supports?(atom()) :: boolean()
end

defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes notifications to one or more channel adapters based on recipient
  preferences and notification type. Falls back to the email channel when
  no preferences are stored.
  """

  alias Notifications.{Channel, PreferencesStore, TemplateRenderer}

  @channel_registry %{
    email: Notifications.Channels.Email,
    sms: Notifications.Channels.Sms,
    push: Notifications.Channels.Push,
    slack: Notifications.Channels.Slack
  }

  @type dispatch_opts :: [timeout: pos_integer(), channels: [atom()]]

  @spec dispatch(Channel.notification(), dispatch_opts()) ::
          {:ok, [atom()]} | {:error, :no_channels | [{atom(), term()}]}
  def dispatch(%{recipient_id: rid, template: template} = notification, opts \\ []) do
    channels = resolve_channels(rid, template, opts)

    if channels == [] do
      {:error, :no_channels}
    else
      results = deliver_to_channels(notification, channels, opts)
      summarize_results(results, channels)
    end
  end

  defp resolve_channels(recipient_id, template, opts) do
    explicit = Keyword.get(opts, :channels)

    if explicit do
      Enum.filter(explicit, &Map.has_key?(@channel_registry, &1))
    else
      preferred = PreferencesStore.fetch(recipient_id)
      Enum.filter(preferred, &channel_supports?(&1, template))
    end
  end

  defp channel_supports?(channel_name, template) do
    case Map.fetch(@channel_registry, channel_name) do
      {:ok, module} -> module.supports?(template)
      :error -> false
    end
  end

  defp deliver_to_channels(notification, channels, opts) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    channels
    |> Enum.map(fn channel ->
      task = Task.async(fn -> deliver_single(notification, channel, opts) end)
      {channel, task}
    end)
    |> Enum.map(fn {channel, task} ->
      result = Task.await(task, timeout)
      {channel, result}
    end)
  end

  defp deliver_single(notification, channel_name, opts) do
    case Map.fetch(@channel_registry, channel_name) do
      {:ok, module} ->
        with {:ok, rendered} <- TemplateRenderer.render(notification.template, notification.variables) do
          module.deliver(%{notification | variables: rendered}, opts)
        end

      :error ->
        {:error, :unknown_channel}
    end
  end

  defp summarize_results(results, channels) do
    failures =
      results
      |> Enum.filter(fn {_, result} -> result != :ok end)
      |> Enum.map(fn {channel, {:error, reason}} -> {channel, reason} end)

    if failures == [] do
      {:ok, channels}
    else
      {:error, failures}
    end
  end
end

defmodule Notifications.PreferencesStore do
  @moduledoc "Looks up stored delivery channel preferences for a recipient."

  @default_channels [:email]

  @spec fetch(String.t()) :: [atom()]
  def fetch(recipient_id) when is_binary(recipient_id) do
    case :ets.lookup(:notification_preferences, recipient_id) do
      [{^recipient_id, channels}] -> channels
      [] -> @default_channels
    end
  end

  @spec set(String.t(), [atom()]) :: :ok
  def set(recipient_id, channels) when is_binary(recipient_id) and is_list(channels) do
    :ets.insert(:notification_preferences, {recipient_id, channels})
    :ok
  end
end
```
