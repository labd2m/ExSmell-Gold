# Annotated Example 33 — Complex else clauses in with

## Metadata

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `send_notification/2`, inside the `with` expression's `else` block
- **Affected function(s):** `send_notification/2`
- **Short explanation:** Four pipeline steps each fail with a different error shape or bare atom. The consolidated `else` block mixes these unrelated patterns, making it hard to know which step produced a given error value.

---

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
    # VALIDATION: SMELL START - Complex else clauses in with
    # VALIDATION: This is a smell because four with-clauses each produce a
    # structurally different error ({:error, :not_found}, :not_found,
    # {:error, :no_channel, _}, {:error, :log, _}). Collapsing all into one
    # else block couples unrelated failure paths and obscures which step
    # is responsible for each pattern.
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
    # VALIDATION: SMELL END
  end
end
```
