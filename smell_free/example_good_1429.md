```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes notification jobs to channel-specific sender modules.
  Channels are registered at startup; dispatch failures are returned explicitly.
  """

  alias Notifications.{Channel, Payload}

  @type dispatch_result :: :ok | {:error, :unknown_channel | term()}

  @doc """
  Dispatches a notification payload over the specified channel.

  Returns `:ok` on successful delivery or `{:error, reason}` on failure.
  """
  @spec dispatch(atom(), Payload.t()) :: dispatch_result()
  def dispatch(channel, %Payload{} = payload) when is_atom(channel) do
    case resolve_channel(channel) do
      {:ok, handler} -> invoke_handler(handler, payload)
      {:error, :unknown_channel} = err -> err
    end
  end

  @doc """
  Dispatches a payload to multiple channels concurrently.
  Returns a keyword list of `{channel, result}` pairs.
  """
  @spec broadcast([atom()], Payload.t()) :: [{atom(), dispatch_result()}]
  def broadcast(channels, %Payload{} = payload) when is_list(channels) do
    channels
    |> Task.async_stream(fn ch -> {ch, dispatch(ch, payload)} end,
      ordered: false,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.map(&unwrap_task_result/1)
  end

  defp resolve_channel(:email), do: {:ok, Notifications.Channel.Email}
  defp resolve_channel(:sms), do: {:ok, Notifications.Channel.Sms}
  defp resolve_channel(:push), do: {:ok, Notifications.Channel.Push}
  defp resolve_channel(:slack), do: {:ok, Notifications.Channel.Slack}
  defp resolve_channel(_unknown), do: {:error, :unknown_channel}

  defp invoke_handler(handler, payload) do
    handler.deliver(payload)
  rescue
    exception -> {:error, {:handler_exception, Exception.message(exception)}}
  end

  defp unwrap_task_result({:ok, {channel, result}}), do: {channel, result}
  defp unwrap_task_result({:exit, reason}), do: {:unknown, {:error, {:task_exit, reason}}}
end

defmodule Notifications.Payload do
  @moduledoc """
  Represents a notification message with recipient and content metadata.
  """

  @type t :: %__MODULE__{
          recipient_id: String.t(),
          subject: String.t(),
          body: String.t(),
          metadata: map()
        }

  defstruct [:recipient_id, :subject, :body, metadata: %{}]

  @doc """
  Builds a validated Payload struct.
  """
  @spec build(map()) :: {:ok, t()} | {:error, String.t()}
  def build(params) when is_map(params) do
    with {:ok, recipient_id} <- require_string(params, :recipient_id),
         {:ok, subject} <- require_string(params, :subject),
         {:ok, body} <- require_string(params, :body) do
      {:ok,
       %__MODULE__{
         recipient_id: recipient_id,
         subject: subject,
         body: body,
         metadata: Map.get(params, :metadata, %{})
       }}
    end
  end

  defp require_string(params, key) do
    case Map.fetch(params, key) do
      {:ok, val} when is_binary(val) and val != "" -> {:ok, val}
      {:ok, _} -> {:error, "#{key} must be a non-empty string"}
      :error -> {:error, "#{key} is required"}
    end
  end
end
```
