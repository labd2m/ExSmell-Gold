```elixir
defmodule Paginator do
  @moduledoc """
  A pagination helper library for Ecto queries and in-memory collections.
  Returns page metadata alongside the windowed data slice.
  Intended to be used in REST API controllers and reporting contexts.
  """

  defmodule Page do
    @enforce_keys [:entries, :page_number, :page_size, :total_entries, :total_pages]
    defstruct [
      :entries,
      :page_number,
      :page_size,
      :total_entries,
      :total_pages,
      :has_next,
      :has_prev
    ]
  end

  @doc """
  Paginates an in-memory list of entries.

  `params` is expected to contain at least a `:page` key (1-based).
  Page size and the maximum allowed page size are taken from
  the application configuration.

  ## Example

      {:ok, page} = Paginator.paginate(my_list, %{"page" => "2"})
  """
  def paginate(entries, params) when is_list(entries) and is_map(params) do
    page_size     = Application.fetch_env!(:paginator, :page_size)
    max_page_size = Application.fetch_env!(:paginator, :max_page_size)

    requested_size =
      params
      |> Map.get("per_page", page_size)
      |> parse_integer(page_size)
      |> min(max_page_size)
      |> max(1)

    page_number =
      params
      |> Map.get("page", 1)
      |> parse_integer(1)
      |> max(1)

    total_entries = length(entries)
    total_pages   = ceil_div(total_entries, requested_size)
    safe_page     = min(page_number, max(total_pages, 1))

    offset = (safe_page - 1) * requested_size

    page_entries = Enum.slice(entries, offset, requested_size)

    page = %Page{
      entries:       page_entries,
      page_number:   safe_page,
      page_size:     requested_size,
      total_entries: total_entries,
      total_pages:   total_pages,
      has_next:      safe_page < total_pages,
      has_prev:      safe_page > 1
    }

    {:ok, page}
  end

  @doc """
  Paginates an Ecto query (expects a repo and a queryable).
  """
  def paginate_query(repo, queryable, params) when is_map(params) do
    page_size = Application.fetch_env!(:paginator, :page_size)

    page_number =
      params
      |> Map.get("page", 1)
      |> parse_integer(1)
      |> max(1)

    total_entries = repo.aggregate(queryable, :count)
    total_pages   = ceil_div(total_entries, page_size)
    safe_page     = min(page_number, max(total_pages, 1))

    import Ecto.Query, only: [limit: 2, offset: 2]

    page_entries =
      queryable
      |> limit(^page_size)
      |> offset(^((safe_page - 1) * page_size))
      |> repo.all()

    page = %Page{
      entries:       page_entries,
      page_number:   safe_page,
      page_size:     page_size,
      total_entries: total_entries,
      total_pages:   total_pages,
      has_next:      safe_page < total_pages,
      has_prev:      safe_page > 1
    }

    {:ok, page}
  end

  @doc """
  Converts a Page struct to a JSON-serializable map for API responses.
  """
  def to_response(%Page{} = page, entry_mapper \\ &Function.identity/1) do
    %{
      data: Enum.map(page.entries, entry_mapper),
      meta: %{
        page:          page.page_number,
        per_page:      page.page_size,
        total:         page.total_entries,
        total_pages:   page.total_pages,
        has_next_page: page.has_next,
        has_prev_page: page.has_prev
      }
    }
  end

  # --- Private helpers ---

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error  -> default
    end
  end

  defp parse_integer(value, _default) when is_integer(value), do: value
  defp parse_integer(_, default), do: default

  defp ceil_div(_, 0), do: 1
  defp ceil_div(n, d), do: div(n + d - 1, d)
end
```
