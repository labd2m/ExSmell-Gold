# File: `example_good_206.md`

```elixir
defmodule Storage.PresignedUrl do
  @moduledoc """
  Generates time-limited presigned URLs for direct client uploads to and
  downloads from S3-compatible object storage.

  URL signing is performed using HMAC-SHA256 (AWS Signature Version 4).
  Credentials are supplied explicitly so this module can support multiple
  storage accounts without relying on process-scoped environment state.
  """

  @algorithm "AWS4-HMAC-SHA256"
  @service "s3"
  @default_expires_seconds 900

  @type credentials :: %{
          required(:access_key_id) => String.t(),
          required(:secret_access_key) => String.t(),
          required(:region) => String.t(),
          required(:bucket) => String.t(),
          required(:host) => String.t()
        }

  @type presign_opts :: [
          expires_seconds: pos_integer(),
          content_type: String.t() | nil,
          metadata: %{String.t() => String.t()}
        ]

  @type presign_result :: {:ok, %{url: String.t(), expires_at: DateTime.t()}}

  @doc """
  Generates a presigned PUT URL for uploading `object_key` directly
  from the client to object storage.

  Options:
  - `:expires_seconds` — URL validity window in seconds (default: 900)
  - `:content_type` — constrains the upload to a specific MIME type
  - `:metadata` — additional object metadata included in the signature

  Returns `{:ok, %{url: url, expires_at: datetime}}`.
  """
  @spec presign_upload(String.t(), credentials(), presign_opts()) :: presign_result()
  def presign_upload(object_key, credentials, opts \\ [])
      when is_binary(object_key) and is_map(credentials) do
    expires_seconds = Keyword.get(opts, :expires_seconds, @default_expires_seconds)
    content_type = Keyword.get(opts, :content_type)

    now = DateTime.utc_now()
    url = build_presigned_url(:put, object_key, credentials, expires_seconds, content_type, now)
    expires_at = DateTime.add(now, expires_seconds, :second)

    {:ok, %{url: url, expires_at: expires_at}}
  end

  @doc """
  Generates a presigned GET URL for downloading `object_key`.
  """
  @spec presign_download(String.t(), credentials(), presign_opts()) :: presign_result()
  def presign_download(object_key, credentials, opts \\ [])
      when is_binary(object_key) and is_map(credentials) do
    expires_seconds = Keyword.get(opts, :expires_seconds, @default_expires_seconds)
    now = DateTime.utc_now()
    url = build_presigned_url(:get, object_key, credentials, expires_seconds, nil, now)
    expires_at = DateTime.add(now, expires_seconds, :second)

    {:ok, %{url: url, expires_at: expires_at}}
  end

  defp build_presigned_url(method, object_key, creds, expires, content_type, now) do
    date_stamp = format_date(now)
    datetime_stamp = format_datetime(now)
    credential_scope = "#{date_stamp}/#{creds.region}/#{@service}/aws4_request"
    credential = "#{creds.access_key_id}/#{credential_scope}"

    query_params =
      %{
        "X-Amz-Algorithm" => @algorithm,
        "X-Amz-Credential" => credential,
        "X-Amz-Date" => datetime_stamp,
        "X-Amz-Expires" => Integer.to_string(expires),
        "X-Amz-SignedHeaders" => "host"
      }
      |> maybe_add_content_type(content_type)
      |> URI.encode_query()

    canonical_uri = "/" <> URI.encode(object_key, &URI.char_unreserved?/1)
    canonical_headers = "host:#{creds.host}\n"
    canonical_request =
      [String.upcase(Atom.to_string(method)), canonical_uri,
       query_params, canonical_headers, "host", "UNSIGNED-PAYLOAD"]
      |> Enum.join("\n")

    string_to_sign =
      [@algorithm, datetime_stamp, credential_scope,
       :crypto.hash(:sha256, canonical_request) |> Base.encode16(case: :lower)]
      |> Enum.join("\n")

    signing_key = derive_signing_key(creds.secret_access_key, date_stamp, creds.region)
    signature = :crypto.mac(:hmac, :sha256, signing_key, string_to_sign) |> Base.encode16(case: :lower)

    "https://#{creds.host}#{canonical_uri}?#{query_params}&X-Amz-Signature=#{signature}"
  end

  defp derive_signing_key(secret, date_stamp, region) do
    :crypto.mac(:hmac, :sha256, "AWS4#{secret}", date_stamp)
    |> then(&:crypto.mac(:hmac, :sha256, &1, region))
    |> then(&:crypto.mac(:hmac, :sha256, &1, @service))
    |> then(&:crypto.mac(:hmac, :sha256, &1, "aws4_request"))
  end

  defp maybe_add_content_type(params, nil), do: params
  defp maybe_add_content_type(params, ct), do: Map.put(params, "Content-Type", ct)

  defp format_date(dt) do
    Calendar.strftime(dt, "%Y%m%d")
  end

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y%m%dT%H%M%SZ")
  end
end
```
