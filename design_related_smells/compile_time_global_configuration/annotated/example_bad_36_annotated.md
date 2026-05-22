# Annotated Example — Compile-time Global Configuration

## Metadata

- **Smell:** Compile-time global configuration
- **Expected Smell Location:** Module attribute `@sms_provider` defined via `Application.fetch_env!/2` at the top of the module body
- **Affected Function(s):** `send_otp/2`, `send_alert/3`
- **Explanation:** `Application.fetch_env!/2` is called at compile-time to lock in the SMS provider atom. Because `:notifications` has not been loaded during compilation, Elixir raises an `ArgumentError` or a warning. The provider choice is frozen in the bytecode, so switching providers during an outage requires a full recompile rather than a config change.

---

```elixir
defmodule Notifications.SmsDispatcher do
  @moduledoc """
  Sends transactional SMS messages (OTP codes, fraud alerts, shipping
  notifications) through a configurable provider. Supported providers
  are :twilio, :vonage, and :aws_sns.
  """

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is invoked
  # VALIDATION: at module-compilation time. The :notifications application has
  # VALIDATION: not been started at that point, so Elixir raises:
  # VALIDATION:   ** (ArgumentError) could not fetch application environment
  # VALIDATION:     :sms_provider for application :notifications
  # VALIDATION: The atom is also baked into the beam, making provider failover
  # VALIDATION: at runtime impossible without recompiling the module.
  @sms_provider Application.fetch_env!(:notifications, :sms_provider)
  # VALIDATION: SMELL END

  @supported_providers [:twilio, :vonage, :aws_sns]
  @otp_ttl_seconds 300
  @otp_digits 6
  @max_retries 2

  @type phone_number :: String.t()
  @type send_result :: :ok | {:error, :invalid_number | :provider_error | :rate_limited}

  @spec send_otp(phone_number(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def send_otp(phone_number, user_id) when is_binary(phone_number) do
    with :ok <- validate_e164(phone_number),
         code = generate_otp(),
         :ok <- store_otp(user_id, code),
         :ok <- deliver_sms(phone_number, otp_message(code)) do
      Logger.info("OTP sent", user_id: user_id, provider: @sms_provider)
      {:ok, code}
    end
  end

  @spec verify_otp(String.t(), String.t()) ::
          :ok | {:error, :invalid_otp | :expired_otp | :not_found}
  def verify_otp(user_id, submitted_code) when is_binary(user_id) do
    case otp_store().fetch(user_id) do
      {:ok, %{code: stored, inserted_at: inserted_at}} ->
        cond do
          DateTime.diff(DateTime.utc_now(), inserted_at) > @otp_ttl_seconds ->
            otp_store().delete(user_id)
            {:error, :expired_otp}

          Plug.Crypto.secure_compare(stored, submitted_code) ->
            otp_store().delete(user_id)
            :ok

          true ->
            {:error, :invalid_otp}
        end

      :not_found ->
        {:error, :not_found}
    end
  end

  @spec send_alert(phone_number(), String.t(), keyword()) :: send_result()
  def send_alert(phone_number, message, _opts \\ []) when is_binary(phone_number) do
    with :ok <- validate_e164(phone_number) do
      deliver_sms(phone_number, message)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp deliver_sms(phone_number, body) do
    deliver_sms(phone_number, body, @max_retries)
  end

  defp deliver_sms(_phone_number, _body, 0), do: {:error, :provider_error}

  defp deliver_sms(phone_number, body, retries_left) do
    case provider_adapter(@sms_provider).send(phone_number, body) do
      :ok ->
        :ok

      {:error, :rate_limited} ->
        {:error, :rate_limited}

      {:error, _reason} when retries_left > 1 ->
        Logger.warning("SMS delivery failed, retrying",
          provider: @sms_provider,
          retries_left: retries_left - 1
        )

        Process.sleep(500)
        deliver_sms(phone_number, body, retries_left - 1)

      {:error, reason} ->
        Logger.error("SMS delivery failed", provider: @sms_provider, reason: inspect(reason))
        {:error, :provider_error}
    end
  end

  defp provider_adapter(:twilio), do: Notifications.Providers.Twilio
  defp provider_adapter(:vonage), do: Notifications.Providers.Vonage
  defp provider_adapter(:aws_sns), do: Notifications.Providers.AwsSns

  defp provider_adapter(other) do
    Logger.error("Unknown SMS provider", provider: other)
    raise "Unsupported SMS provider: #{inspect(other)}"
  end

  defp validate_e164(number) do
    if String.match?(number, ~r/\A\+[1-9]\d{7,14}\z/), do: :ok, else: {:error, :invalid_number}
  end

  defp generate_otp do
    @otp_digits
    |> :crypto.strong_rand_bytes()
    |> :binary.decode_unsigned()
    |> rem(trunc(:math.pow(10, @otp_digits)))
    |> Integer.to_string()
    |> String.pad_leading(@otp_digits, "0")
  end

  defp store_otp(user_id, code) do
    otp_store().put(user_id, %{code: code, inserted_at: DateTime.utc_now()})
  end

  defp otp_message(code), do: "Your verification code is #{code}. It expires in 5 minutes."

  defp otp_store, do: Application.get_env(:notifications, :otp_store, Notifications.OtpStore)
end
```
