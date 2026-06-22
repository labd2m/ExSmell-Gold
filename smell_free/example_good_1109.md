```elixir
defmodule Search.QueryBuilder do
  @moduledoc """
  Builds structured search query maps from user-supplied filter parameters.
  Each supported filter type is handled by a dedicated private clause,
  making it straightforward to add or remove filter support.
  """

  @type filter_params :: %{
          optional(:term) => String.t(),
          optional(:tags) => [String.t()],
          optional(:date_from) => Date.t(),
          optional(:date_to) => Date.t(),
          optional(:status) => String.t()
        }

  @type query :: map()

  @supported_statuses ~w(active inactive archived)

  @doc """
  Constructs a query map from the given filter parameters.
  Unrecognized or nil parameters are silently ignored.
  """
  @spec build(filter_params()) :: {:ok, query()} | {:error, term()}
  def build(params) when is_map(params) do
    with {:ok, filters} <- collect_filters(params) do
      {:ok, %{filters: filters, version: 1}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp collect_filters(params) do
    [:term, :tags, :date_from, :date_to, :status]
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, acc} ->
      case build_filter(key, Map.get(params, key)) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, filter} -> {:cont, {:ok, [filter | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, filters} -> {:ok, Enum.reverse(filters)}
      error -> error
    end
  end

  defp build_filter(:term, nil), do: {:ok, nil}
  defp build_filter(:term, term) when is_binary(term) and byte_size(term) > 0,
    do: {:ok, %{type: :full_text, value: String.trim(term)}}
  defp build_filter(:term, _), do: {:error, {:invalid_filter, :term}}

  defp build_filter(:tags, nil), do: {:ok, nil}
  defp build_filter(:tags, []), do: {:ok, nil}
  defp build_filter(:tags, tags) when is_list(tags) do
    if Enum.all?(tags, &is_binary/1) do
      {:ok, %{type: :tags, values: Enum.map(tags, &String.downcase/1)}}
    else
      {:error, {:invalid_filter, :tags}}
    end
  end

  defp build_filter(:date_from, nil), do: {:ok, nil}
  defp build_filter(:date_from, %Date{} = d), do: {:ok, %{type: :date_from, value: d}}
  defp build_filter(:date_from, _), do: {:error, {:invalid_filter, :date_from}}

  defp build_filter(:date_to, nil), do: {:ok, nil}
  defp build_filter(:date_to, %Date{} = d), do: {:ok, %{type: :date_to, value: d}}
  defp build_filter(:date_to, _), do: {:error, {:invalid_filter, :date_to}}

  defp build_filter(:status, nil), do: {:ok, nil}
  defp build_filter(:status, s) when is_binary(s) and s in @supported_statuses,
    do: {:ok, %{type: :status, value: s}}
  defp build_filter(:status, _), do: {:error, {:invalid_filter, :status}}
end

defmodule Search.QuerySerializer do
  @moduledoc """
  Converts a structured query map into a URL-encoded query string
  suitable for forwarding to a downstream search service.
  """

  @doc "Encodes a query map as a URI query string."
  @spec to_query_string(map()) :: String.t()
  def to_query_string(%{filters: filters, version: version}) do
    filter_pairs = Enum.flat_map(filters, &filter_to_pairs/1)
    all_pairs = [{"version", Integer.to_string(version)} | filter_pairs]
    URI.encode_query(all_pairs)
  end

  defp filter_to_pairs(%{type: :full_text, value: v}), do: [{"q", v}]
  defp filter_to_pairs(%{type: :status, value: v}), do: [{"status", v}]
  defp filter_to_pairs(%{type: :tags, values: tags}),
    do: Enum.map(tags, fn t -> {"tag[]", t} end)
  defp filter_to_pairs(%{type: :date_from, value: d}),
    do: [{"date_from", Date.to_iso8601(d)}]
  defp filter_to_pairs(%{type: :date_to, value: d}),
    do: [{"date_to", Date.to_iso8601(d)}]
end
```
