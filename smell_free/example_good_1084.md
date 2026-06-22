```elixir
defmodule Notifications.DispatchRouter do
  @moduledoc """
  Routes outbound notifications to the correct delivery channel adapter
  based on recipient preferences and message urgency classification.
  """

  alias Notifications.{EmailAdapter, SmsAdapter, PushAdapter, Preference}

  @type message :: %{
          recipient_id: String.t(),
          subject: String.t(),
          body: String.t(),
          urgency: :low | :normal | :high | :critical
        }

  @type dispatch_result ::
          {:ok, reference()}
          | {:error, :no_channel_available | :delivery_failed}

  @spec dispatch(message()) :: dispatch_result()
  def dispatch(%{urgency: :critical} = message) do
    deliver_with_fallback(message, [SmsAdapter, PushAdapter, EmailAdapter])
  end

  def dispatch(%{urgency: :high} = message) do
    deliver_with_fallback(message, [PushAdapter, EmailAdapter])
  end

  def dispatch(%{urgency: urgency} = message) when urgency in [:normal, :low] do
    deliver_with_fallback(message, [EmailAdapter])
  end

  @spec dispatch_with_preference(message(), Preference.t()) :: dispatch_result()
  def dispatch_with_preference(message, %Preference{channels: channels}) do
    adapters = resolve_adapters(channels)

    case adapters do
      [] -> {:error, :no_channel_available}
      _ -> deliver_with_fallback(message, adapters)
    end
  end

  @spec deliver_with_fallback(message(), [module()]) :: dispatch_result()
  defp deliver_with_fallback(_message, []) do
    {:error, :no_channel_available}
  end

  defp deliver_with_fallback(message, [adapter | rest]) do
    case adapter.deliver(message) do
      {:ok, ref} -> {:ok, ref}
      {:error, _reason} -> deliver_with_fallback(message, rest)
    end
  end

  @spec resolve_adapters([atom()]) :: [module()]
  defp resolve_adapters(channels) do
    channel_map = %{
      email: EmailAdapter,
      sms: SmsAdapter,
      push: PushAdapter
    }

    channels
    |> Enum.map(&Map.get(channel_map, &1))
    |> Enum.reject(&is_nil/1)
  end
end
```
