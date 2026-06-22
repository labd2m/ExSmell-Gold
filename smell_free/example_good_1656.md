```elixir
defmodule SlackNotifier.Attachment do
  @moduledoc """
  A structured Slack message attachment with optional fields and color coding.
  """

  @type color :: :good | :warning | :danger | String.t()

  @type t :: %__MODULE__{
          title: String.t() | nil,
          text: String.t(),
          color: color(),
          fields: [%{title: String.t(), value: String.t(), short: boolean()}],
          footer: String.t() | nil,
          ts: integer() | nil
        }

  defstruct [:title, :text, :footer, :ts, color: :good, fields: []]

  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = attachment) do
    base = %{
      text: attachment.text,
      color: format_color(attachment.color),
      fields: Enum.map(attachment.fields, &format_field/1)
    }

    base
    |> maybe_put(:title, attachment.title)
    |> maybe_put(:footer, attachment.footer)
    |> maybe_put(:ts, attachment.ts)
  end

  defp format_color(:good), do: "good"
  defp format_color(:warning), do: "warning"
  defp format_color(:danger), do: "danger"
  defp format_color(hex) when is_binary(hex), do: hex

  defp format_field(%{title: t, value: v, short: s}), do: %{title: t, value: v, short: s}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule SlackNotifier do
  alias SlackNotifier.Attachment

  @moduledoc """
  Delivers messages and structured attachments to Slack channels via
  the Incoming Webhooks API. Configuration is supplied per-call to support
  multiple workspace targets in the same application.
  """

  @type config :: %{webhook_url: String.t()}

  @spec send_message(String.t(), String.t(), config()) :: :ok | {:error, term()}
  def send_message(channel, text, config)
      when is_binary(channel) and is_binary(text) and is_map(config) do
    payload = %{channel: channel, text: text}
    post_payload(payload, config)
  end

  @spec send_attachment(String.t(), Attachment.t(), config()) :: :ok | {:error, term()}
  def send_attachment(channel, %Attachment{} = attachment, config) when is_binary(channel) do
    payload = %{
      channel: channel,
      attachments: [Attachment.to_payload(attachment)]
    }

    post_payload(payload, config)
  end

  @spec send_blocks(String.t(), [map()], config()) :: :ok | {:error, term()}
  def send_blocks(channel, blocks, config)
      when is_binary(channel) and is_list(blocks) and is_map(config) do
    payload = %{channel: channel, blocks: blocks}
    post_payload(payload, config)
  end

  defp post_payload(payload, %{webhook_url: url}) do
    headers = [{"content-type", "application/json"}]

    case Req.post(url, body: Jason.encode!(payload), headers: headers) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_response, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end
end
```
