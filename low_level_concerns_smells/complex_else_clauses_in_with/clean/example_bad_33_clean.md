```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Dispatches push, email, and SMS notifications based on user preferences
  and template definitions.
  """

  alias Notifications.{
    UserPreferenceStore,
    TemplateRegistry,
    ChannelRouter,
    DeliveryLog
  }

  require Logger

  @doc """
  Sends a notification of `type` to `recipient_id`.

  `payload` is merged with template variables during rendering.

  Returns `{:ok, delivery_id}` or a structured error.
  """
  @spec send_notification(String.t(), map()) ::
          {:ok, String.t()}
          | {:error, :recipient_not_found}
          | {:error, :template_missing}
          | {:error, :channel_unavailable}
          | {:error, :delivery_log_failed}
  def send_notification(recipient_id, %{type: type} = payload) do
    with {:ok, prefs}    <- UserPreferenceStore.fetch(recipient_id),
         {:ok, template} <- TemplateRegistry.get(type, prefs.locale),
         {:ok, channel}  <- ChannelRouter.resolve(prefs, template.channels),
         {:ok, delivery} <- channel.send(recipient_id, template, payload) do
      DeliveryLog.record!(delivery)
      Logger.info("Notification sent: #{delivery.id} to #{recipient_id} via #{channel.name}")
      {:ok, delivery.id}
    else
      {:error, :not_found} ->
        Logger.warn("Recipient #{recipient_id} not found in preference store")
        {:error, :recipient_not_found}

      :not_found ->
        Logger.warn("No template for type=#{type}")
        {:error, :template_missing}

      {:error, :no_channel, tried} ->
        Logger.warn("No available channel from candidates: #{inspect(tried)}")
        {:error, :channel_unavailable}

      {:error, :log, reason} ->
        Logger.error("Delivery log persistence failed: #{inspect(reason)}")
        {:error, :delivery_log_failed}
    end
  end
end
```
