```elixir
defmodule Marketplace.ListingSearch do
  @moduledoc """
  Provides full-text and faceted search over marketplace listings.
  Queries are built compositionally: callers chain filter helpers and
  then materialise results with `execute/2`. Pagination uses keyset
  cursors rather than offset counting to stay stable under concurrent
  insertions. All query building is pure; only `execute/2` touches
  the database.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Marketplace.Listing

  @type query_opts :: [
          term: String.t(),
          category_slug: String.t(),
          min_price_cents: non_neg_integer(),
          max_price_cents: non_neg_integer(),
          seller_id: String.t(),
          condition: String.t(),
          sort: :price_asc | :price_desc | :newest | :relevance
        ]

  @default_limit 24
  @max_limit 100

  @doc "Builds the base query for active listings."
  @spec base_query() :: Ecto.Query.t()
  def base_query do
    from(l in Listing, where: l.status == "active")
  end

  @doc "Applies all filters from `opts` to `query` in a single pass."
  @spec filter(Ecto.Query.t(), query_opts()) :: Ecto.Query.t()
  def filter(query, opts) when is_list(opts) do
    query
    |> maybe_text_search(Keyword.get(opts, :term))
    |> maybe_category(Keyword.get(opts, :category_slug))
    |> maybe_price_range(Keyword.get(opts, :min_price_cents), Keyword.get(opts, :max_price_cents))
    |> maybe_seller(Keyword.get(opts, :seller_id))
    |> maybe_condition(Keyword.get(opts, :condition))
  end

  @doc "Applies a sort ordering to `query`."
  @spec sort(Ecto.Query.t(), :price_asc | :price_desc | :newest | :relevance) :: Ecto.Query.t()
  def sort(query, :price_asc), do: order_by(query, [l], asc: l.price_cents, asc: l.id)
  def sort(query, :price_desc), do: order_by(query, [l], desc: l.price_cents, asc: l.id)
  def sort(query, :newest), do: order_by(query, [l], desc: l.inserted_at, asc: l.id)
  def sort(query, _), do: order_by(query, [l], desc: l.inserted_at)

  @doc """
  Executes `query`, returning a page of results and a cursor for the
  next page. `limit` is capped at #{@max_limit}.
  """
  @spec execute(Ecto.Query.t(), keyword()) ::
          %{listings: [Listing.t()], next_cursor: String.t() | nil, has_more: boolean()}
  def execute(query, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit)

    results =
      query
      |> limit(^(limit + 1))
      |> Repo.all()

    has_more = length(results) > limit
    listings = Enum.take(results, limit)
    next_cursor = if has_more, do: encode_cursor(List.last(listings)), else: nil

    %{listings: listings, next_cursor: next_cursor, has_more: has_more}
  end

  defp maybe_text_search(query, nil), do: query
  defp maybe_text_search(query, ""), do: query

  defp maybe_text_search(query, term) when is_binary(term) do
    pattern = "%#{String.replace(term, ["%", "_"], fn c -> "\\#{c}" end)}%"
    where(query, [l], ilike(l.title, ^pattern) or ilike(l.description, ^pattern))
  end

  defp maybe_category(query, nil), do: query
  defp maybe_category(query, slug), do: where(query, [l], l.category_slug == ^slug)

  defp maybe_price_range(query, nil, nil), do: query
  defp maybe_price_range(query, min, nil) when is_integer(min),
    do: where(query, [l], l.price_cents >= ^min)
  defp maybe_price_range(query, nil, max) when is_integer(max),
    do: where(query, [l], l.price_cents <= ^max)
  defp maybe_price_range(query, min, max) when is_integer(min) and is_integer(max),
    do: where(query, [l], l.price_cents >= ^min and l.price_cents <= ^max)

  defp maybe_seller(query, nil), do: query
  defp maybe_seller(query, id), do: where(query, [l], l.seller_id == ^id)

  defp maybe_condition(query, nil), do: query
  defp maybe_condition(query, cond_val), do: where(query, [l], l.condition == ^cond_val)

  defp encode_cursor(%Listing{id: id, inserted_at: ts}) do
    "#{DateTime.to_unix(ts, :millisecond)}_#{id}"
    |> Base.url_encode64(padding: false)
  end
end
```
