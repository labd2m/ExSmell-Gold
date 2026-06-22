```elixir
defmodule MyApp.Notifications.ChannelRouter do
  @moduledoc """
  Selects the optimal delivery channel for a notification based on the
  recipient's reachability, the notification's urgency, and the
  recipient's preferences. The routing decision is deterministic and
  purely functional; no I/O occurs inside this module.

  Channel selection follows a strict priority order: critical alerts
  always use SMS regardless of preferences, while low-urgency items
  prefer in-app delivery and only fall back to email when the recipient
  is not currently online.
  """

  @type urgency :: :critical | :high | :normal | :low
  @type channel :: :sms | :email | :push | :in_app

  @type recipient_context :: %{
          required(:has_phone) => boolean(),
          required(:has_push_token) => boolean(),
          required(:is_online) => boolean(),
          required(:opted_out_channels) => [channel()],
          optional(:preferred_channel) => channel() | nil
        }

  @type routing_decision :: %{
          channel: channel(),
          reason: String.t()
        }

  @doc """
  Selects the best delivery channel for `urgency` given `context`.
  Always returns a decision; falls back to `:in_app` when all preferred
  channels are unavailable.
  """
  @spec route(urgency(), recipient_context()) :: routing_decision()
  def route(:critical, context) do
    cond do
      context.has_phone and sms_available?(context) ->
        decide(:sms, "critical_always_sms")

      context.has_push_token and push_available?(context) ->
        decide(:push, "critical_push_fallback")

      true ->
        decide(:email, "critical_email_fallback")
    end
  end

  def route(:high, context) do
    cond do
      context.has_push_token and push_available?(context) ->
        decide(:push, "high_priority_push")

      email_available?(context) ->
        decide(:email, "high_priority_email")

      true ->
        decide(:in_app, "high_priority_in_app_fallback")
    end
  end

  def route(:normal, context) do
    preferred = Map.get(context, :preferred_channel)

    cond do
      preferred != nil and channel_available?(preferred, context) ->
        decide(preferred, "user_preference")

      context.is_online ->
        decide(:in_app, "recipient_online")

      email_available?(context) ->
        decide(:email, "offline_email")

      true ->
        decide(:in_app, "default_in_app")
    end
  end

  def route(:low, context) do
    if context.is_online do
      decide(:in_app, "low_urgency_in_app")
    else
      decide(:email, "low_urgency_email_digest")
    end
  end

  @doc "Returns the ordered list of fallback channels for `urgency`."
  @spec fallback_order(urgency()) :: [channel()]
  def fallback_order(:critical), do: [:sms, :push, :email, :in_app]
  def fallback_order(:high), do: [:push, :email, :in_app]
  def fallback_order(:normal), do: [:in_app, :email, :push]
  def fallback_order(:low), do: [:in_app, :email]

  @spec channel_available?(channel(), recipient_context()) :: boolean()
  defp channel_available?(:sms, ctx), do: sms_available?(ctx)
  defp channel_available?(:push, ctx), do: push_available?(ctx)
  defp channel_available?(:email, ctx), do: email_available?(ctx)
  defp channel_available?(:in_app, _ctx), do: true

  @spec sms_available?(recipient_context()) :: boolean()
  defp sms_available?(ctx), do: ctx.has_phone and :sms not in ctx.opted_out_channels

  @spec push_available?(recipient_context()) :: boolean()
  defp push_available?(ctx), do: ctx.has_push_token and :push not in ctx.opted_out_channels

  @spec email_available?(recipient_context()) :: boolean()
  defp email_available?(ctx), do: :email not in ctx.opted_out_channels

  @spec decide(channel(), String.t()) :: routing_decision()
  defp decide(channel, reason), do: %{channel: channel, reason: reason}
end
```
