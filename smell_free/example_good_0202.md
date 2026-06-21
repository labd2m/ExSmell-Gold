# File: `example_good_202.md`

```elixir
defmodule Notifications.PreferenceRouter do
  @moduledoc """
  Routes outbound notifications to the correct delivery channels based
  on each recipient's stored preferences and the notification's category.

  The routing decision is pure and deterministic given a preference record
  and a notification descriptor. Channel dispatch is the caller's concern.
  """

  alias Notifications.{Channel, Preference}

  @type notification_category ::
          :transactional | :marketing | :security | :product_update | :digest

  @type notification :: %{
          required(:category) => notification_category(),
          required(:recipient_id) => String.t(),
          required(:payload) => map()
        }

  @type routing_decision :: %{
          recipient_id: String.t(),
          channels: [Channel.t()],
          suppressed: boolean(),
          suppression_reason: atom() | nil
        }

  @mandatory_categories [:transactional, :security]

  @doc """
  Determines which channels a notification should be delivered through
  based on the recipient's preferences.

  Notifications in `:transactional` and `:security` categories are always
  delivered through at least the email channel regardless of preferences.

  Returns a `routing_decision` indicating the resolved channels and
  whether the notification was fully suppressed.
  """
  @spec route(notification(), Preference.t()) :: routing_decision()
  def route(%{category: category, recipient_id: recipient_id}, %Preference{} = pref) do
    if globally_suppressed?(pref) do
      build_suppressed_decision(recipient_id, :global_opt_out)
    else
      channels = resolve_channels(category, pref)
      build_delivery_decision(recipient_id, channels)
    end
  end

  @doc """
  Returns `true` when the recipient has opted out of all non-mandatory
  notification categories.
  """
  @spec fully_opted_out?(Preference.t()) :: boolean()
  def fully_opted_out?(%Preference{} = pref) do
    globally_suppressed?(pref)
  end

  @doc """
  Returns the list of channels that would be used for a given category
  if the notification were sent to a recipient with these preferences.
  """
  @spec preview_channels(notification_category(), Preference.t()) :: [Channel.t()]
  def preview_channels(category, %Preference{} = pref) do
    resolve_channels(category, pref)
  end

  defp globally_suppressed?(%Preference{global_opt_out: true}), do: true
  defp globally_suppressed?(_pref), do: false

  defp resolve_channels(category, pref) do
    category
    |> enabled_channels_for_category(pref)
    |> add_mandatory_channels(category, pref)
    |> Enum.uniq()
    |> Enum.filter(&channel_reachable?(pref, &1))
  end

  defp enabled_channels_for_category(category, pref) do
    category_prefs = Map.get(pref.category_settings, category, %{})

    Enum.flat_map(Channel.all(), fn channel ->
      if Map.get(category_prefs, channel, true) do
        [channel]
      else
        []
      end
    end)
  end

  defp add_mandatory_channels(channels, category, pref) when category in @mandatory_categories do
    mandatory = Enum.filter([:email], &channel_reachable?(pref, &1))
    Enum.uniq(mandatory ++ channels)
  end

  defp add_mandatory_channels(channels, _category, _pref), do: channels

  defp channel_reachable?(%Preference{email: email}, :email) do
    is_binary(email) and byte_size(email) > 0
  end

  defp channel_reachable?(%Preference{phone_number: phone}, :sms) do
    is_binary(phone) and byte_size(phone) > 0
  end

  defp channel_reachable?(%Preference{push_token: token}, :push) do
    is_binary(token) and byte_size(token) > 0
  end

  defp channel_reachable?(_pref, _channel), do: false

  defp build_delivery_decision(recipient_id, []) do
    %{
      recipient_id: recipient_id,
      channels: [],
      suppressed: true,
      suppression_reason: :no_reachable_channels
    }
  end

  defp build_delivery_decision(recipient_id, channels) do
    %{recipient_id: recipient_id, channels: channels, suppressed: false, suppression_reason: nil}
  end

  defp build_suppressed_decision(recipient_id, reason) do
    %{recipient_id: recipient_id, channels: [], suppressed: true, suppression_reason: reason}
  end
end
```
