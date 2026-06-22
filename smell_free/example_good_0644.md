```elixir
defmodule Storage.SignedUrl do
  @moduledoc """
  Generates cryptographically signed, time-limited URLs for private assets.
  The signature covers the resource path, expiry timestamp, allowed HTTP
  method, and an optional scope claim so a URL issued for a download cannot
  be replayed as an upload. Verification happens in the `VerifyPlug` which
  is mounted on the asset delivery router.
  """

  require Logger

  @hash_alg :sha256
  @signature_param "_sig"
  @expires_param "_exp"
  @scope_param "_scope"

  @type sign_opts :: [
          ttl_seconds: pos_integer(),
          method: :get | :put | :delete,
          scope: binary() | nil
        ]

  @doc """
  Returns a signed URL for `path` that is valid for `:ttl_seconds` (default 3600).
  The `:method` option restricts which HTTP method the URL is valid for.
  An optional `:scope` string (e.g. `"tenant:abc123"`) is bound into the signature.
  """
  @spec sign(binary(), sign_opts()) :: binary()
  def sign(path, opts \\ []) when is_binary(path) do
    ttl = Keyword.get(opts, :ttl_seconds, 3_600)
    method = Keyword.get(opts, :method, :get) |> Atom.to_string() |> String.upcase()
    scope = Keyword.get(opts, :scope, "")
    expires_at = System.system_time(:second) + ttl

    signature = compute_signature(path, expires_at, method, scope)

    params =
      URI.encode_query(%{
        @expires_param => expires_at,
        @scope_param => scope,
        @signature_param => signature
      })

    base_url() <> path <> "?" <> params
  end

  @doc """
  Verifies a signed URL against the current time and expected method/scope.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec verify(binary(), binary(), binary()) ::
          :ok | {:error, :expired | :invalid_signature | :invalid_url}
  def verify(url, method \\ "GET", expected_scope \\ "") when is_binary(url) do
    with {:ok, path, params} <- parse_url(url),
         {:ok, expires_at} <- fetch_param(params, @expires_param, :integer),
         {:ok, scope} <- fetch_param(params, @scope_param, :string),
         {:ok, received_sig} <- fetch_param(params, @signature_param, :string),
         :ok <- check_scope(scope, expected_scope),
         :ok <- check_expiry(expires_at),
         :ok <- check_signature(path, expires_at, method, scope, received_sig) do
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp compute_signature(path, expires_at, method, scope) do
    message = Enum.join([path, expires_at, method, scope], ":")
    secret = Application.fetch_env!(:my_app, :signed_url_secret)

    :crypto.mac(:hmac, @hash_alg, secret, message)
    |> Base.url_encode64(padding: false)
  end

  defp parse_url(url) do
    uri = URI.parse(url)

    case uri do
      %URI{path: path, query: query} when is_binary(path) and is_binary(query) ->
        {:ok, path, URI.decode_query(query)}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp fetch_param(params, key, :integer) do
    case Map.get(params, key) do
      nil -> {:error, :invalid_url}
      raw ->
        case Integer.parse(raw) do
          {val, ""} -> {:ok, val}
          _ -> {:error, :invalid_url}
        end
    end
  end

  defp fetch_param(params, key, :string) do
    case Map.get(params, key) do
      nil -> {:error, :invalid_url}
      val -> {:ok, val}
    end
  end

  defp check_expiry(expires_at) do
    if System.system_time(:second) <= expires_at do
      :ok
    else
      {:error, :expired}
    end
  end

  defp check_scope(scope, expected) when scope == expected, do: :ok
  defp check_scope(_scope, _expected), do: {:error, :invalid_signature}

  defp check_signature(path, expires_at, method, scope, received) do
    expected = compute_signature(path, expires_at, String.upcase(method), scope)

    if Plug.Crypto.secure_compare(expected, received) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp base_url do
    Application.get_env(:my_app, :asset_base_url, "https://assets.example.com")
  end
end
```
