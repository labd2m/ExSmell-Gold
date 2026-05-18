```elixir
defmodule Reporting.Paginator do
  @moduledoc """
  Provides pagination, sorting, and filtering helpers for report
  datasets returned from the data warehouse layer.
  """

  @default_page_size 25
  @max_page_size 200

  defmacro paginate(items, page, size) do
    quote do
      raw_size = unquote(size)
      clamped_size = min(max(raw_size, 1), unquote(@max_page_size))
      current_page = max(unquote(page), 1)
      all_items = unquote(items)
      total = length(all_items)
      total_pages = max(ceil(total / clamped_size), 1)
      offset = (current_page - 1) * clamped_size

      %{
        data: Enum.slice(all_items, offset, clamped_size),
        page: current_page,
        page_size: clamped_size,
        total_items: total,
        total_pages: total_pages
      }
    end
  end

  def sort(items, field, direction \\ :asc) do
    sorted = Enum.sort_by(items, &Map.get(&1, field))
    if direction == :desc, do: Enum.reverse(sorted), else: sorted
  end

  def filter(items, filters) when is_map(filters) do
    Enum.filter(items, fn item ->
      Enum.all?(filters, fn {key, value} ->
        Map.get(item, key) == value
      end)
    end)
  end

  def filter_by_date_range(items, date_field, from_dt, to_dt) do
    Enum.filter(items, fn item ->
      dt = Map.get(item, date_field)
      DateTime.compare(dt, from_dt) != :lt and
        DateTime.compare(dt, to_dt) != :gt
    end)
  end

  def search(items, text_fields, query) do
    downcased = String.downcase(query)

    Enum.filter(items, fn item ->
      Enum.any?(text_fields, fn field ->
        value = Map.get(item, field, "")
        String.contains?(String.downcase(to_string(value)), downcased)
      end)
    end)
  end

  def build_report(raw_data, params) do
    require Reporting.Paginator

    filtered =
      raw_data
      |> filter(Map.get(params, :filters, %{}))
      |> search(
        Map.get(params, :search_fields, [:name]),
        Map.get(params, :query, "")
      )
      |> sort(
        Map.get(params, :sort_by, :inserted_at),
        Map.get(params, :sort_dir, :desc)
      )

    page = Map.get(params, :page, 1)
    size = Map.get(params, :page_size, @default_page_size)

    Reporting.Paginator.paginate(filtered, page, size)
  end

  def export_all(raw_data, filters, sort_field) do
    raw_data
    |> filter(filters)
    |> sort(sort_field)
  end

  def aggregate(items, group_field, value_field) do
    items
    |> Enum.group_by(&Map.get(&1, group_field))
    |> Enum.map(fn {key, group} ->
      total = Enum.reduce(group, 0, fn i, acc -> acc + Map.get(i, value_field, 0) end)
      %{group: key, total: total, count: length(group)}
    end)
  end
end
```
