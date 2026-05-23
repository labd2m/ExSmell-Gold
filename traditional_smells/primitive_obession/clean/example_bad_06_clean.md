```elixir
defmodule Notifications.SmsDispatcher do
  @moduledoc """
  Dispatches transactional SMS messages through the carrier gateway.
  Handles phone number validation, normalisation to E.164 format,
  opt-in management, and delivery status tracking.
  """

  require Logger

  @max_message_length 160
  @default_country_code "1"
  @opt_in_store :sms_opt_ins

  @spec send_sms(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def send_sms(recipient_phone, message, sender_id) do
    with {:ok, normalised} <- normalize_phone(recipient_phone),
         true <- opted_in?(normalised),
         :ok <- validate_message_length(message),
         {:ok, carrier} <- lookup_carrier(normalised) do
      payload = %{
        to: normalised,
        from: sender_id,
        body: message,
        carrier: carrier,
        sent_at: DateTime.utc_now()
      }

      Logger.info("SMS dispatched to #{mask_phone(normalised)} via #{carrier}")
      {:ok, Map.put(payload, :message_id, generate_message_id())}
    else
      false ->
        {:error, "Phone number #{mask_phone(recipient_phone)} has not opted in"}

      {:error, reason} ->
        Logger.error("SMS dispatch failed for #{mask_phone(recipient_phone)}: #{reason}")
        {:error, reason}
    end
  end

  @spec validate_phone(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_phone(phone) do
    digits = String.replace(phone, ~r/[\s\-().+]/, "")

    cond do
      not String.match?(digits, ~r/^\d{7,15}$/) ->
        {:error, "Phone number contains invalid characters or has wrong length: #{phone}"}

      String.length(digits) < 7 ->
        {:error, "Phone number too short: #{phone}"}

      true ->
        {:ok, digits}
    end
  end

  @spec normalize_phone(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_phone(phone) do
    with {:ok, digits} <- validate_phone(phone) do
      normalised =
        cond do
          String.starts_with?(digits, "+") ->
            digits

          String.starts_with?(digits, "00") ->
            "+" <> String.slice(digits, 2..-1//1)

          String.length(digits) == 10 ->
            "+#{@default_country_code}#{digits}"

          String.length(digits) == 11 and String.starts_with?(digits, "1") ->
            "+#{digits}"

          true ->
            "+#{digits}"
        end

      {:ok, normalised}
    end
  end

  @spec opt_in_phone(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def opt_in_phone(phone, user_id) do
    with {:ok, normalised} <- normalize_phone(phone) do
      :ets.insert(@opt_in_store, {normalised, user_id, DateTime.utc_now()})
      Logger.info("Phone #{mask_phone(normalised)} opted in for user #{user_id}")
      {:ok, normalised}
    end
  end

  @spec opt_out_phone(String.t()) :: :ok | {:error, String.t()}
  def opt_out_phone(phone) do
    with {:ok, normalised} <- normalize_phone(phone) do
      :ets.delete(@opt_in_store, normalised)
      Logger.info("Phone #{mask_phone(normalised)} opted out")
      :ok
    end
  end

  @spec lookup_carrier(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def lookup_carrier(phone) do
    with {:ok, normalised} <- normalize_phone(phone) do
      carrier =
        cond do
          String.starts_with?(normalised, "+1") -> "US_ATT"
          String.starts_with?(normalised, "+44") -> "UK_EE"
          String.starts_with?(normalised, "+55") -> "BR_VIVO"
          true -> "INTL_GATEWAY"
        end

      {:ok, carrier}
    end
  end

  @spec mask_phone(String.t()) :: String.t()
  def mask_phone(phone) do
    if String.length(phone) >= 4 do
      masked = String.duplicate("*", String.length(phone) - 4)
      masked <> String.slice(phone, -4, 4)
    else
      "****"
    end
  end

  defp opted_in?(normalised_phone) do
    case :ets.lookup(@opt_in_store, normalised_phone) do
      [{^normalised_phone, _user_id, _at}] -> true
      [] -> false
    end
  rescue
    _ -> false
  end

  defp validate_message_length(message) do
    if String.length(message) <= @max_message_length do
      :ok
    else
      {:error,
       "Message exceeds #{@max_message_length} characters (got #{String.length(message)})"}
    end
  end

  defp generate_message_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
