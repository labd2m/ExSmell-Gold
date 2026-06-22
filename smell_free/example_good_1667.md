```elixir
defmodule Search.Query do
  @moduledoc """
  A structured search query with typed filter and sort specifications.
  """

  @type sort_order :: :asc | :desc
  @type filter :: %{field: String.t(), op: :eq | :range | :prefix, value: term()}

  @type t :: %__MODULE__{
          text: String.t() | nil,
          filters: [filter()],
          sort_by: String.t() | nil,
          sort_order: sort_order(),
          page: pos_integer(),
          per_page: pos_integer()
        }

  defstruct [
    text: nil,
    filters: [],
    sort_by: nil,
    sort_order: :desc,
    page: 1,
    per_page: 20
  ]
end

defmodule Search.Result do
  @moduledoc """
  The outcome of a search operation with pagination metadata.
  """

  @type t :: %__MODULE__{
          hits: [map()],
          total: non_neg_integer(),
          page: pos_integer(),
          per_page: pos_integer(),
          total_pages: non_neg_integer(),
          took_ms: non_neg_integer()
        }

  defstruct [:hits, :total, :page, :per_page, :total_pages, :took_ms]
end

defmodule Search.ElasticsearchBackend do
  alias Search.{Query, Result}

  @moduledoc """
  Translates `Search.Query` structs into Elasticsearch DSL requests
  and maps responses to `Search.Result` structs.
  """

  @type config :: %{base_url: String.t(), index: String.t(), api_key: String.t()}

  @spec search(Query.t(), config()) :: {:ok, Result.t()} | {:error, term()}
  def search(%Query{} = query, %{base_url: url, index: index, api_key: key}) do
    body = build_request_body(query)
    endpoint = "#{url}/#{index}/_search"
    headers = [{"authorization", "ApiKey #{key}"}, {"content-type", "application/json"}]
    start = System.monotonic_time(:millisecond)

    case Req.post(endpoint, body: Jason.encode!(body), headers: headers) do
      {:ok, %{status: 200, body: resp}} ->
        took_ms = System.monotonic_time(:millisecond) - start
        {:ok, parse_response(resp, query, took_ms)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:elasticsearch_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp build_request_body(%Query{} = q) do
    from = (q.page - 1) * q.per_page

    base = %{from: from, size: q.per_page, query: build_query(q)}

    base
    |> maybe_add_sort(q.sort_by, q.sort_order)
  end

  defp build_query(%Query{text: nil, filters: []}), do: %{match_all: %{}}

  defp build_query(%Query{text: text, filters: filters}) do
    musts =
      []
      |> add_text_clause(text)
      |> add_filter_clauses(filters)

    %{bool: %{must: musts}}
  end

  defp add_text_clause(clauses, nil), do: clauses

  defp add_text_clause(clauses, text) do
    [%{multi_match: %{query: text, type: "best_fields"}} | clauses]
  end

  defp add_filter_clauses(clauses, []), do: clauses

  defp add_filter_clauses(clauses, filters) do
    filter_clauses = Enum.map(filters, &build_filter/1)
    clauses ++ filter_clauses
  end

  defp build_filter(%{field: f, op: :eq, value: v}), do: %{term: %{f => v}}
  defp build_filter(%{field: f, op: :prefix, value: v}), do: %{prefix: %{f => v}}

  defp build_filter(%{field: f, op: :range, value: %{gte: min, lte: max}}) do
    %{range: %{f => %{gte: min, lte: max}}}
  end

  defp maybe_add_sort(body, nil, _order), do: body

  defp maybe_add_sort(body, field, order) do
    Map.put(body, :sort, [%{field => %{order: Atom.to_string(order)}}])
  end

  defp parse_response(resp, %Query{page: page, per_page: per_page}, took_ms) do
    total = get_in(resp, ["hits", "total", "value"]) || 0
    hits = get_in(resp, ["hits", "hits"]) || []
    sources = Enum.map(hits, fn h -> Map.get(h, "_source", %{}) end)

    %Result{
      hits: sources,
      total: total,
      page: page,
      per_page: per_page,
      total_pages: ceil(total / per_page),
      took_ms: took_ms
    }
  end
end
```
