```elixir
defmodule Accounts.UserProfile do
  @moduledoc """
  Manages user profile data including contact information updates,
  phone verification workflows, and display formatting for the
  customer-facing dashboard.
  """

  require Logger

  alias Accounts.Repo
  alias Accounts.Schema.User
  alias Accounts.Notifications.SMSGateway

  @e164_regex ~r/^\+[1-9]\d{6,14}$/
  @max_verification_attempts 3


  @spec update_phone(User.t(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def update_phone(%User{} = user, phone_number) when is_binary(phone_number) do
    with {:ok, normalized} <- normalize_phone(phone_number),
         :ok <- validate_phone_uniqueness(normalized, user.id),
         {:ok, updated_user} <-
           user
           |> User.changeset(%{
             phone: normalized,
             phone_verified: false,
             phone_verification_sent_at: nil,
             phone_verification_attempts: 0
           })
           |> Repo.update() do
      Logger.info("Phone updated for user=#{user.id} to #{mask_phone(normalized)}")
      {:ok, updated_user}
    end
  end

  @spec send_verification_sms(User.t()) :: :ok | {:error, term()}
  def send_verification_sms(%User{phone: phone} = user) when is_binary(phone) do
    cond do
      user.phone_verification_attempts >= @max_verification_attempts ->
        {:error, :max_attempts_exceeded}

      is_nil(phone) or phone == "" ->
        {:error, :no_phone_on_file}

      not Regex.match?(@e164_regex, phone) ->
        {:error, {:invalid_phone_format, phone}}

      true ->
        code = generate_verification_code()
        country_code = extract_country_code(phone)

        message = build_sms_body(code, country_code)

        case SMSGateway.send(phone, message) do
          :ok ->
            user
            |> User.changeset(%{
              phone_verification_code: hash_code(code),
              phone_verification_sent_at: DateTime.utc_now(),
              phone_verification_attempts: user.phone_verification_attempts + 1
            })
            |> Repo.update()

            :ok

          {:error, reason} ->
            Logger.error("SMS dispatch failed for user=#{user.id}: #{inspect(reason)}")
            {:error, :sms_dispatch_failed}
        end
    end
  end

  @spec format_phone_display(String.t()) :: String.t()
  def format_phone_display(phone) when is_binary(phone) do
    country_code = extract_country_code(phone)
    national = String.slice(phone, String.length(country_code)..-1//1)

    case country_code do
      "+1" -> format_nanp(national)
      "+55" -> format_brazil(national)
      "+44" -> format_uk(national)
      _ -> phone
    end
  end

  @spec normalize_phone(String.t()) :: {:ok, String.t()} | {:error, term()}
  def normalize_phone(raw) when is_binary(raw) do
    cleaned = Regex.replace(~r/[\s\-().+]/, raw, "")
    with_plus = if String.starts_with?(cleaned, "+"), do: cleaned, else: "+#{cleaned}"

    if Regex.match?(@e164_regex, with_plus) do
      {:ok, with_plus}
    else
      {:error, {:invalid_phone, raw}}
    end
  end


  ## Private helpers

  defp extract_country_code(phone) when is_binary(phone) do
    cond do
      String.starts_with?(phone, "+1") -> "+1"
      String.starts_with?(phone, "+55") -> "+55"
      String.starts_with?(phone, "+44") -> "+44"
      String.starts_with?(phone, "+49") -> "+49"
      true -> String.slice(phone, 0, 3)
    end
  end

  defp format_nanp(national) do
    "(#{String.slice(national, 0, 3)}) #{String.slice(national, 3, 3)}-#{String.slice(national, 6, 4)}"
  end

  defp format_brazil(national) do
    "(#{String.slice(national, 0, 2)}) #{String.slice(national, 2, 5)}-#{String.slice(national, 7, 4)}"
  end

  defp format_uk(national) do
    "#{String.slice(national, 0, 4)} #{String.slice(national, 4, 3)} #{String.slice(national, 7, 4)}"
  end

  defp mask_phone(phone) when is_binary(phone) do
    len = String.length(phone)
    String.slice(phone, 0, 4) <> String.duplicate("*", len - 8) <> String.slice(phone, -4, 4)
  end

  defp validate_phone_uniqueness(phone, user_id) do
    case Repo.get_by(User, phone: phone) do
      nil -> :ok
      %User{id: ^user_id} -> :ok
      _ -> {:error, :phone_already_taken}
    end
  end

  defp generate_verification_code do
    :crypto.strong_rand_bytes(3) |> Base.encode16() |> String.slice(0, 6)
  end

  defp hash_code(code), do: :crypto.hash(:sha256, code) |> Base.encode16()

  defp build_sms_body(code, _country_code), do: "Your verification code is: #{code}"
end
```