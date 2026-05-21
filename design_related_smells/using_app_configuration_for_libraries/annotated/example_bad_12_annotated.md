# Annotated Example 12

## Metadata

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `Paginator.paginate/2`
- **Affected function(s):** `paginate/2`
- **Short explanation:** `Paginator.paginate/2` reads `:default_page_size` and `:max_page_size` from the application environment instead of accepting them as optional keyword parameters. This means that all paginated queries in the system share the same page-size constraints, making it impossible for one module to paginate 10 records while another paginates 100 without touching global config.

## Code

```elixir
defmodule Paginator do
  @moduledoc """
  A general-purpose cursor-free offset/limit pagination library for Ecto-based
  applications. Computes pagination metadata and injects limit/offset into a
  queryable pipeline.

  Configuration in `config/config.exs`:

      config :paginator,
        default_page_size: 20,
        max_page_size: 100
  """

  import Ecto.Query, warn: false

  defstruct [:entries, :page_number, :page_size, :total_entries, :total_pages]

  @doc """
  Paginates the given Ecto queryable using the provided repo and page params.

  `params` may include:
    - `page` (integer, default 1)
    - `page_size` (integer, capped to configured max)
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because default_page_size and max_page_size are
  # fetched from the Application Environment. Any caller wanting a different page
  # size policy (e.g., an admin endpoint vs a public API) must change global config,
  # rather than just passing options to this function.
  def paginate(queryable, params \\ %{}) do
    default_size = Application.fetch_env!(:paginator, :default_page_size)
    max_size = Application.fetch_env!(:paginator, :max_page_size)

    page = params |> Map.get("page", 1) |> to_integer() |> max(1)
    requested_size = params |> Map.get("page_size", default_size) |> to_integer()
    page_size = min(requested_size, max_size)

    offset = (page - 1) * page_size

    {queryable, page, page_size, offset}
  end
  # VALIDATION: SMELL END

  @doc """
  Builds a `Paginator` struct from the pre-fetched entries and pagination params.

  Callers are responsible for executing the query with the given offset and limit,
  and for supplying the total entry count from a separate `COUNT` query.
  """
  def build_result(entries, total_entries, page, page_size)
      when is_list(entries) and is_integer(total_entries) do
    total_pages = ceil(total_entries / page_size)

    %__MODULE__{
      entries: entries,
      page_number: page,
      page_size: page_size,
      total_entries: total_entries,
      total_pages: total_pages
    }
  end

  @doc """
  Returns `true` if there is a next page.
  """
  def has_next?(%__MODULE__{page_number: p, total_pages: t}), do: p < t

  @doc """
  Returns `true` if there is a previous page.
  """
  def has_prev?(%__MODULE__{page_number: p}), do: p > 1

  @doc """
  Returns a map suitable for including in a JSON API response envelope.
  """
  def meta(%__MODULE__{} = page) do
    %{
      page_number: page.page_number,
      page_size: page.page_size,
      total_entries: page.total_entries,
      total_pages: page.total_pages,
      has_next: has_next?(page),
      has_prev: has_prev?(page)
    }
  end

  @doc """
  Applies limit and offset to an Ecto query.
  """
  def apply_query(queryable, limit, offset) do
    queryable
    |> limit(^limit)
    |> offset(^offset)
  end

  ## Private helpers

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 1
    end
  end

  defp to_integer(_), do: 1
end
```
