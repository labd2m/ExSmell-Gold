```elixir
defmodule Messaging.SmsAdapter do
  @moduledoc """
  Sends outbound SMS messages through a configurable carrier gateway.
  Normalises phone numbers to E.164 format before dispatch and returns
  a structured delivery receipt with the provider-assigned message ID.
  """

  alias Messaging.{PhoneNormalizer, GatewayClient}

  @type recipient :: %{phone: String.t(), country_code: String.t()}

  @type sms_message :: %{
          to: recipient(),
          body: String.t(),
          sender_id: String.t()
        }

  @type delivery_receipt :: %{
          provider_id: String.t(),
          to: String.t(),
          status: :accepted | :rejected,
          accepted_at: DateTime.t()
        }

  @max_body_bytes 1_600

  @spec deliver(sms_message()) :: {:ok, delivery_receipt()} | {:error, atom()}
  def deliver(%{to: recipient, body: body, sender_id: sender_id}) do
    with :ok <- validate_body(body),
         {:ok, e164} <- PhoneNormalizer.to_e164(recipient.phone, recipient.country_code),
         {:ok, response} <- GatewayClient.send_sms(%{to: e164, body: body, from: sender_id}) do
      {:ok, build_receipt(response, e164)}
    end
  end

  @spec deliver_batch([sms_message()]) :: %{
          delivered: [delivery_receipt()],
          failed: [%{message: sms_message(), reason: atom()}]
        }
  def deliver_batch(messages) when is_list(messages) do
    Enum.reduce(messages, %{delivered: [], failed: []}, fn msg, acc ->
      case deliver(msg) do
        {:ok, receipt} ->
          Map.update!(acc, :delivered, &[receipt | &1])

        {:error, reason} ->
          Map.update!(acc, :failed, &[%{message: msg, reason: reason} | &1])
      end
    end)
  end

  @spec validate_body(String.t()) :: :ok | {:error, :body_too_long | :body_empty}
  defp validate_body(body) when is_binary(body) do
    cond do
      byte_size(body) == 0 -> {:error, :body_empty}
      byte_size(body) > @max_body_bytes -> {:error, :body_too_long}
      true -> :ok
    end
  end

  defp validate_body(_), do: {:error, :body_empty}

  @spec build_receipt(map(), String.t()) :: delivery_receipt()
  defp build_receipt(response, e164) do
    %{
      provider_id: response.message_id,
      to: e164,
      status: :accepted,
      accepted_at: DateTime.utc_now()
    }
  end
end
```
