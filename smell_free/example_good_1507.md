```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes outbound notifications to the appropriate delivery channel
  based on user preferences and notification type.

  Supported channels: `:email`, `:sms`, `:push`.
  Each channel adapter implements the `Notifications.Channel` behaviour.
  """

  alias Notifications.Channel
  alias Notifications.Preference
  alias Notifications.DeliveryLog

  @type notification :: %{
          required(:user_id) => String.t(),
          required(:type) => atom(),
          required(:payload) => map()
        }

  @type dispatch_result ::
          {:ok, DeliveryLog.t()}
          | {:error, :no_channel_configured}
          | {:error, :delivery_failed, term()}

  @doc """
  Dispatches a notification to the user's preferred delivery channel.

  Looks up the user's channel preference, selects the appropriate
  adapter, and delegates delivery. Returns a delivery log entry on
  success.
  """
  @spec dispatch(notification()) :: dispatch_result()
  def dispatch(%{user_id: user_id, type: type, payload: payload}) do
    with {:ok, channel} <- Preference.resolve_channel(user_id, type),
         {:ok, adapter} <- resolve_adapter(channel),
         {:ok, reference} <- Channel.deliver(adapter, user_id, payload) do
      log = DeliveryLog.record(user_id, type, channel, reference)
      {:ok, log}
    else
      {:error, :no_preference} -> {:error, :no_channel_configured}
      {:error, :unknown_channel} -> {:error, :no_channel_configured}
      {:error, reason} -> {:error, :delivery_failed, reason}
    end
  end

  @doc """
  Dispatches a notification to an explicit channel, bypassing user preferences.

  Useful for system-level or administrative notifications.
  """
  @spec dispatch_to(notification(), Channel.channel_name()) :: dispatch_result()
  def dispatch_to(%{user_id: user_id, type: type, payload: payload}, channel)
      when is_atom(channel) do
    with {:ok, adapter} <- resolve_adapter(channel),
         {:ok, reference} <- Channel.deliver(adapter, user_id, payload) do
      log = DeliveryLog.record(user_id, type, channel, reference)
      {:ok, log}
    else
      {:error, :unknown_channel} -> {:error, :no_channel_configured}
      {:error, reason} -> {:error, :delivery_failed, reason}
    end
  end

  @spec resolve_adapter(atom()) ::
          {:ok, module()} | {:error, :unknown_channel}
  defp resolve_adapter(:email), do: {:ok, Notifications.Adapters.Email}
  defp resolve_adapter(:sms), do: {:ok, Notifications.Adapters.SMS}
  defp resolve_adapter(:push), do: {:ok, Notifications.Adapters.Push}
  defp resolve_adapter(_), do: {:error, :unknown_channel}
end

defmodule Notifications.Channel do
  @moduledoc """
  Behaviour contract for notification channel adapters.
  """

  @type channel_name :: :email | :sms | :push
  @type user_id :: String.t()
  @type payload :: map()
  @type delivery_reference :: String.t()

  @callback deliver(user_id(), payload()) ::
              {:ok, delivery_reference()} | {:error, term()}

  @doc """
  Delegates delivery to the given adapter module.
  """
  @spec deliver(module(), user_id(), payload()) ::
          {:ok, delivery_reference()} | {:error, term()}
  def deliver(adapter, user_id, payload) when is_atom(adapter) do
    adapter.deliver(user_id, payload)
  end
end
```
