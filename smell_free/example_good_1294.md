```elixir
defmodule Cdn.PurgeClient do
  @moduledoc """
  Issues cache purge requests to a pluggable CDN provider.

  Purge operations accept either individual URLs or tag-based wildcard patterns.
  The provider adapter is supplied per-call to enable per-zone configuration
  and straightforward test injection without modifying global state.
  """

  alias Cdn.PurgeClient.{PurgeRequest, PurgeResult, Adapter}

  @doc """
  Purges one or more specific URLs from the CDN cache.

  Returns a `PurgeResult` summarising successful and failed URLs.
  """
  @spec purge_urls([String.t()], Adapter.t()) :: {:ok, PurgeResult.t()} | {:error, String.t()}
  def purge_urls(urls, %Adapter{} = adapter) when is_list(urls) and urls != [] do
    with :ok <- validate_urls(urls) do
      request = PurgeRequest.by_urls(urls)
      adapter.module.purge(adapter.credentials, request)
    end
  end

  def purge_urls([], _), do: {:error, "at least one URL is required"}
  def purge_urls(_, _), do: {:error, "invalid arguments"}

  @doc """
  Purges all cached objects matching the given cache tags.
  """
  @spec purge_tags([String.t()], Adapter.t()) :: {:ok, PurgeResult.t()} | {:error, String.t()}
  def purge_tags(tags, %Adapter{} = adapter) when is_list(tags) and tags != [] do
    with :ok <- validate_tags(tags) do
      request = PurgeRequest.by_tags(tags)
      adapter.module.purge(adapter.credentials, request)
    end
  end

  def purge_tags([], _), do: {:error, "at least one tag is required"}
  def purge_tags(_, _), do: {:error, "invalid arguments"}

  @doc """
  Purges everything under a given path prefix.
  """
  @spec purge_prefix(String.t(), Adapter.t()) :: {:ok, PurgeResult.t()} | {:error, String.t()}
  def purge_prefix(prefix, %Adapter{} = adapter) when is_binary(prefix) and prefix != "" do
    request = PurgeRequest.by_prefix(prefix)
    adapter.module.purge(adapter.credentials, request)
  end

  def purge_prefix(_, _), do: {:error, "invalid prefix"}

  defp validate_urls(urls) do
    invalid = Enum.reject(urls, &valid_url?/1)

    if invalid == [],
      do: :ok,
      else: {:error, "invalid URLs: #{Enum.join(invalid, ", ")}"}
  end

  defp validate_tags(tags) do
    invalid = Enum.reject(tags, &is_binary/1)
    if invalid == [], do: :ok, else: {:error, "all tags must be strings"}
  end

  defp valid_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: s, host: h} when is_binary(s) and is_binary(h) -> true
      _ -> false
    end
  end

  defp valid_url?(_), do: false
end

defmodule Cdn.PurgeClient.PurgeRequest do
  @moduledoc "Typed descriptor for a CDN purge operation."

  @enforce_keys [:type, :targets]
  defstruct [:type, :targets]

  @type purge_type :: :urls | :tags | :prefix
  @type t :: %__MODULE__{type: purge_type(), targets: [String.t()]}

  @spec by_urls([String.t()]) :: t()
  def by_urls(urls), do: %__MODULE__{type: :urls, targets: urls}

  @spec by_tags([String.t()]) :: t()
  def by_tags(tags), do: %__MODULE__{type: :tags, targets: tags}

  @spec by_prefix(String.t()) :: t()
  def by_prefix(prefix), do: %__MODULE__{type: :prefix, targets: [prefix]}
end

defmodule Cdn.PurgeClient.PurgeResult do
  @moduledoc "Outcome of a CDN purge request."

  @enforce_keys [:succeeded, :failed, :total]
  defstruct [:succeeded, :failed, :total, :provider_reference]

  @type t :: %__MODULE__{
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          total: non_neg_integer(),
          provider_reference: String.t() | nil
        }

  @spec new(non_neg_integer(), non_neg_integer(), String.t() | nil) :: t()
  def new(succeeded, failed, ref \\ nil) do
    %__MODULE__{succeeded: succeeded, failed: failed, total: succeeded + failed, provider_reference: ref}
  end
end

defmodule Cdn.PurgeClient.Adapter do
  @moduledoc "Wraps a CDN provider module with its credentials."

  @enforce_keys [:module, :credentials]
  defstruct [:module, :credentials]

  @type t :: %__MODULE__{module: module(), credentials: map()}

  @callback purge(map(), Cdn.PurgeClient.PurgeRequest.t()) ::
              {:ok, Cdn.PurgeClient.PurgeResult.t()} | {:error, String.t()}

  @spec new(module(), map()) :: t()
  def new(module, credentials) when is_atom(module) and is_map(credentials) do
    %__MODULE__{module: module, credentials: credentials}
  end
end
```
