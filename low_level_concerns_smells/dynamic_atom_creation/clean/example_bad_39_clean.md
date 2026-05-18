```elixir
defmodule Notifications.PushRegistrar do
  @moduledoc """
  Manages device token registration and deregistration for mobile push
  notifications. Stores tokens per user and device type for targeted delivery.
  """

  require Logger

  alias Notifications.{DeviceTokenRepo, PushValidator, UserRepo}

  @token_max_length 512

  @spec register(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def register(user_id, params) do
    Logger.info("Registering push token", user_id: user_id)

    with {:ok, user} <- UserRepo.get(user_id),
         :ok <- validate_registration_params(params),
         {:ok, device_type} <- parse_device_type(params["device_type"]),
         {:ok, token} <- validate_token(params["token"]),
         {:ok, device_record} <-
           DeviceTokenRepo.upsert(%{
             user_id: user.id,
             device_type: device_type,
             token: token,
             device_id: params["device_id"],
             app_version: params["app_version"],
             os_version: params["os_version"],
             registered_at: DateTime.utc_now()
           }) do
      Logger.info("Push token registered", user_id: user_id, device_type: device_type)
      {:ok, device_record}
    else
      {:error, reason} = err ->
        Logger.error("Push token registration failed",
          user_id: user_id,
          reason: inspect(reason)
        )
        err
    end
  end

  @spec deregister(String.t(), String.t()) :: :ok | {:error, term()}
  def deregister(user_id, device_id) do
    Logger.info("Deregistering push token", user_id: user_id, device_id: device_id)

    case DeviceTokenRepo.delete_by_device(user_id, device_id) do
      {:ok, _} ->
        Logger.info("Push token deregistered", user_id: user_id)
        :ok

      {:error, :not_found} ->
        Logger.warning("Token not found for deregistration", device_id: device_id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec list_tokens(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_tokens(user_id) do
    DeviceTokenRepo.list_for_user(user_id)
  end

  defp validate_registration_params(params) do
    required = ~w(device_type token device_id)
    missing = Enum.reject(required, &Map.has_key?(params, &1))

    if missing == [],
      do: :ok,
      else: {:error, {:missing_fields, missing}}
  end

  defp parse_device_type(nil), do: {:error, :missing_device_type}

  defp parse_device_type(type) when is_binary(type) do
    parsed =
      type
      |> String.trim()
      |> String.downcase()
      |> String.to_atom()

    {:ok, parsed}
  end

  defp parse_device_type(_), do: {:error, :invalid_device_type}

  defp validate_token(nil), do: {:error, :missing_token}

  defp validate_token(token) when is_binary(token) do
    cond do
      String.length(token) > @token_max_length ->
        {:error, :token_too_long}

      not PushValidator.valid_token_format?(token) ->
        {:error, :invalid_token_format}

      true ->
        {:ok, token}
    end
  end

  defp validate_token(_), do: {:error, :invalid_token}
end
```
