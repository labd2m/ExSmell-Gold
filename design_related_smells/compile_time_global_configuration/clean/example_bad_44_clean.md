```elixir
defmodule PushNotifications.ApnsAdapter do
  @moduledoc """
  Sends Apple Push Notification service (APNs) messages to iOS devices.
  Uses HTTP/2 token-based authentication (JWT). Supports single and
  bulk delivery, background pushes, and notification collapse IDs.
  """

  require Logger

  @apns_topic Application.fetch_env!(:push_notifications, :apns_topic)

  @apns_prod_host "api.push.apple.com"
  @apns_sandbox_host "api.sandbox.push.apple.com"
  @apns_port 443
  @token_ttl_seconds 3_000
  @push_type_alert "alert"
  @push_type_background "background"
  @max_payload_bytes 4_096

  @type device_token :: String.t()
  @type notification :: %{
          title: String.t(),
          body: String.t(),
          badge: non_neg_integer() | nil,
          sound: String.t() | nil,
          data: map(),
          collapse_id: String.t() | nil
        }

  @type push_result :: :ok | {:error, :invalid_token | :bad_device_token | :apns_error}

  @spec push(device_token(), notification(), keyword()) :: push_result()
  def push(device_token, notification, opts \\ []) when is_binary(device_token) do
    with :ok <- validate_token_format(device_token),
         {:ok, payload} <- build_payload(notification),
         :ok <- validate_payload_size(payload),
         bearer = bearer_token(),
         {:ok, response} <- post_to_apns(device_token, payload, bearer, opts) do
      handle_response(device_token, response)
    end
  end

  @spec push_bulk([device_token()], notification(), keyword()) ::
          %{ok: [device_token()], failed: [{device_token(), atom()}]}
  def push_bulk(device_tokens, notification, opts \\ []) when is_list(device_tokens) do
    device_tokens
    |> Task.async_stream(
      fn token -> {token, push(token, notification, opts)} end,
      max_concurrency: 20,
      timeout: 10_000
    )
    |> Enum.reduce(%{ok: [], failed: []}, fn
      {:ok, {token, :ok}}, acc -> Map.update!(acc, :ok, &[token | &1])
      {:ok, {token, {:error, reason}}}, acc -> Map.update!(acc, :failed, &[{token, reason} | &1])
      {:exit, _reason}, acc -> acc
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_payload(%{title: title, body: body} = notification) do
    aps =
      %{"alert" => %{"title" => title, "body" => body}}
      |> maybe_put("badge", notification[:badge])
      |> maybe_put("sound", notification[:sound] || "default")

    payload =
      %{"aps" => aps}
      |> Map.merge(notification[:data] || %{})

    {:ok, Jason.encode!(payload)}
  rescue
    _ -> {:error, :payload_encoding_failed}
  end

  defp validate_payload_size(payload) when byte_size(payload) > @max_payload_bytes,
    do: {:error, :payload_too_large}

  defp validate_payload_size(_), do: :ok

  defp validate_token_format(token) do
    if String.match?(token, ~r/\A[0-9a-f]{64}\z/i), do: :ok, else: {:error, :invalid_token}
  end

  defp post_to_apns(device_token, payload, bearer, opts) do
    sandbox? = Keyword.get(opts, :sandbox, apns_sandbox?())
    host = if sandbox?, do: @apns_sandbox_host, else: @apns_prod_host
    collapse_id = opts[:collapse_id]
    push_type = if opts[:background], do: @push_type_background, else: @push_type_alert

    headers =
      [
        {"authorization", "bearer #{bearer}"},
        {"apns-topic", @apns_topic},
        {"apns-push-type", push_type},
        {"content-type", "application/json"}
      ]
      |> maybe_add_header("apns-collapse-id", collapse_id)
      |> maybe_add_header("apns-expiration", opts[:expiration])

    url = "https://#{host}:#{@apns_port}/3/device/#{device_token}"
    http_client().post(url, payload, headers, http2: true, timeout: 5_000)
  end

  defp handle_response(_token, %{status: 200}), do: :ok

  defp handle_response(token, %{status: 410, body: body}) do
    Logger.info("APNs: device token unregistered", token: token, body: body)
    {:error, :bad_device_token}
  end

  defp handle_response(token, %{status: status, body: body}) do
    Logger.warning("APNs error", token: token, status: status, body: body)
    {:error, :apns_error}
  end

  defp bearer_token do
    key_id = Application.fetch_env!(:push_notifications, :apns_key_id)
    team_id = Application.fetch_env!(:push_notifications, :apns_team_id)
    private_key = Application.fetch_env!(:push_notifications, :apns_private_key)
    now = System.system_time(:second)

    header = Base.url_encode64(~s({"alg":"ES256","kid":"#{key_id}"}), padding: false)
    claims = Base.url_encode64(~s({"iss":"#{team_id}","iat":#{now}}), padding: false)
    signing_input = "#{header}.#{claims}"

    signature =
      :crypto.sign(:ecdsa, :sha256, signing_input, [private_key, :prime256v1])
      |> Base.url_encode64(padding: false)

    "#{signing_input}.#{signature}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_add_header(headers, _name, nil), do: headers
  defp maybe_add_header(headers, name, value), do: [{name, to_string(value)} | headers]

  defp apns_sandbox?, do: Application.get_env(:push_notifications, :apns_sandbox, false)
  defp http_client, do: Application.get_env(:push_notifications, :http_client, PushNotifications.HttpClient)
end
```
