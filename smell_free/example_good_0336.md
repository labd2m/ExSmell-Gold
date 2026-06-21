```elixir
defmodule Platform.ObjectStore do
  @moduledoc """
  Context for storing and retrieving objects in an S3-compatible backend.

  Provides a clean domain API over the underlying storage adapter, handling
  key namespacing, metadata tagging, and pre-signed URL generation without
  leaking adapter implementation details into callers.
  """

  alias Platform.ObjectStore.Adapter

  @type bucket :: String.t()
  @type object_key :: String.t()
  @type upload_opts :: [content_type: String.t(), metadata: map(), public: boolean()]
  @type upload_result :: {:ok, %{key: object_key(), url: String.t()}} | {:error, term()}
  @type presign_opts :: [expires_in: pos_integer(), disposition: String.t()]

  @default_presign_ttl_seconds 900

  @doc """
  Uploads `content` to the default bucket under a namespaced `key`.

  The key is prefixed with `namespace/` to logically separate object types.
  Returns the storage key and public or private URL on success.
  """
  @spec upload(String.t(), String.t(), binary(), upload_opts()) :: upload_result()
  def upload(namespace, filename, content, opts \\ [])
      when is_binary(namespace) and is_binary(filename) and is_binary(content) do
    key = build_key(namespace, filename)
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    metadata = Keyword.get(opts, :metadata, %{})
    public = Keyword.get(opts, :public, false)

    adapter_opts = [
      content_type: content_type,
      metadata: stringify_metadata(metadata),
      acl: if(public, do: "public-read", else: "private")
    ]

    case Adapter.put_object(bucket(), key, content, adapter_opts) do
      :ok -> {:ok, %{key: key, url: object_url(key, public)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Downloads an object by its storage key.
  Returns `{:ok, %{body: binary(), content_type: String.t()}}` or an error.
  """
  @spec download(object_key()) :: {:ok, %{body: binary(), content_type: String.t()}} | {:error, term()}
  def download(key) when is_binary(key) do
    case Adapter.get_object(bucket(), key) do
      {:ok, %{body: body, content_type: ct}} -> {:ok, %{body: body, content_type: ct}}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Generates a pre-signed URL for temporary access to a private object.
  Defaults to a 15-minute expiry window.
  """
  @spec presign_download(object_key(), presign_opts()) :: {:ok, String.t()} | {:error, term()}
  def presign_download(key, opts \\ []) when is_binary(key) do
    expires_in = Keyword.get(opts, :expires_in, @default_presign_ttl_seconds)
    disposition = Keyword.get(opts, :disposition)

    adapter_opts = [expires_in: expires_in] ++ if(disposition, do: [response_content_disposition: disposition], else: [])
    Adapter.presign_url(bucket(), key, :get, adapter_opts)
  end

  @doc "Deletes an object by key. Returns `:ok` even if the object does not exist."
  @spec delete(object_key()) :: :ok | {:error, term()}
  def delete(key) when is_binary(key) do
    Adapter.delete_object(bucket(), key)
  end

  @doc "Returns `true` if an object with the given key exists in the bucket."
  @spec exists?(object_key()) :: boolean()
  def exists?(key) when is_binary(key) do
    case Adapter.head_object(bucket(), key) do
      {:ok, _} -> true
      {:error, :not_found} -> false
      {:error, _} -> false
    end
  end

  defp build_key(namespace, filename) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    unique = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "#{namespace}/#{timestamp}_#{unique}_#{filename}"
  end

  defp object_url(key, true), do: "https://#{bucket()}.s3.amazonaws.com/#{key}"
  defp object_url(key, false), do: "/private/#{key}"

  defp stringify_metadata(metadata) do
    Map.new(metadata, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp bucket do
    Application.fetch_env!(:platform, :object_store_bucket)
  end
end
```
