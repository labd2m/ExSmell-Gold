```elixir
defmodule Pagination.Page do
  @moduledoc """
  An immutable struct representing a single page of results with
  associated pagination metadata for rendering navigation UI.
  """

  @enforce_keys [:entries, :total_entries, :page_number, :page_size]
  defstruct [:entries, :total_entries, :page_number, :page_size]

  @type t(entry) :: %__MODULE__{
          entries: list(entry),
          total_entries: non_neg_integer(),
          page_number: pos_integer(),
          page_size: pos_integer()
        }

  @spec total_pages(t(term())) :: non_neg_integer()
  def total_pages(%__MODULE__{total_entries: total, page_size: size}) do
    ceil(total / size)
  end

  @spec has_next?(t(term())) :: boolean()
  def has_next?(%__MODULE__{} = page), do: page.page_number < total_pages(page)

  @spec has_prev?(t(term())) :: boolean()
  def has_prev?(%__MODULE__{page_number: n}), do: n > 1

  @spec first_entry_index(t(term())) :: non_neg_integer()
  def first_entry_index(%__MODULE__{page_number: n, page_size: size}), do: (n - 1) * size + 1

  @spec last_entry_index(t(term())) :: non_neg_integer()
  def last_entry_index(%__MODULE__{} = page) do
    min(page.page_number * page.page_size, page.total_entries)
  end
end

defmodule Pagination.Params do
  @moduledoc """
  Parses and validates raw pagination parameters from controller or GraphQL input.
  """

  @type t :: %__MODULE__{page: pos_integer(), page_size: pos_integer()}

  defstruct page: 1, page_size: 20

  @min_page 1
  @min_page_size 1
  @max_page_size 200

  @spec from_map(map()) :: {:ok, t()} | {:error, list({atom(), String.t()})}
  def from_map(params) when is_map(params) do
    page = parse_positive_integer(Map.get(params, :page, 1), 1)
    page_size = parse_positive_integer(Map.get(params, :page_size, 20), 20)

    errors =
      []
      |> validate_page(page)
      |> validate_page_size(page_size)

    if Enum.empty?(errors) do
      {:ok, %__MODULE__{page: page, page_size: page_size}}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  defp parse_positive_integer(value, default) when is_integer(value) and value > 0, do: value
  defp parse_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_positive_integer(_value, default), do: default

  defp validate_page(errors, page) when is_integer(page) and page >= @min_page, do: errors
  defp validate_page(errors, _), do: [{:page, "must be at least #{@min_page}"} | errors]

  defp validate_page_size(errors, size)
       when is_integer(size) and size >= @min_page_size and size <= @max_page_size,
       do: errors

  defp validate_page_size(errors, _) do
    [{:page_size, "must be between #{@min_page_size} and #{@max_page_size}"} | errors]
  end
end

defmodule Pagination.Query do
  @moduledoc """
  Applies pagination parameters to Ecto queryables and wraps results in
  a `Pagination.Page` struct including a separate count query for metadata.
  """

  import Ecto.Query, warn: false

  alias Pagination.{Page, Params}

  @spec paginate(Ecto.Queryable.t(), Params.t(), module()) :: Page.t(term())
  def paginate(queryable, %Params{page: page, page_size: size}, repo) do
    total = count_total(queryable, repo)
    offset = (page - 1) * size

    entries =
      queryable
      |> limit(^size)
      |> offset(^offset)
      |> repo.all()

    %Page{
      entries: entries,
      total_entries: total,
      page_number: page,
      page_size: size
    }
  end

  defp count_total(queryable, repo) do
    queryable
    |> exclude(:order_by)
    |> exclude(:select)
    |> select([r], count(r.id))
    |> repo.one()
    |> Kernel.||(0)
  end
end
```
