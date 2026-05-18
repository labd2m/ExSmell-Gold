```elixir
defmodule UserManagement.CollectionUtils do
  @moduledoc """
  Collection and list manipulation helpers used in the user management
  context for cleaning, deduplicating, and normalising input data.
  """

  defmacro reject_blank(list) do
    quote do
      Enum.reject(unquote(list), fn item ->
        not is_binary(item) or String.trim(item) == ""
      end)
    end
  end

  @doc """
  Removes duplicate values from a list, preserving first-occurrence order.
  """
  @spec deduplicate(list()) :: list()
  def deduplicate(items) do
    items
    |> Enum.reduce({[], MapSet.new()}, fn item, {acc, seen} ->
      if MapSet.member?(seen, item) do
        {acc, seen}
      else
        {[item | acc], MapSet.put(seen, item)}
      end
    end)
    |> then(fn {acc, _} -> Enum.reverse(acc) end)
  end

  @doc """
  Splits a list into two based on a predicate function.
  Returns `{matching, non_matching}`.
  """
  @spec partition(list(), (any() -> boolean())) :: {list(), list()}
  def partition(items, pred_fn) do
    Enum.split_with(items, pred_fn)
  end

  @doc """
  Zips a list of keys with a list of values into a map, ignoring extra elements.
  """
  @spec zip_to_map(list(), list()) :: map()
  def zip_to_map(keys, values) do
    keys
    |> Enum.zip(values)
    |> Map.new()
  end
end

defmodule UserManagement.BulkImportService do
  @moduledoc """
  Handles bulk import of user records from CSV uploads or API payloads.
  Cleanses input fields, validates entries, and reports per-row outcomes.
  """

  require UserManagement.CollectionUtils

  alias UserManagement.CollectionUtils

  @required_fields ~w(email first_name last_name)
  @max_tags 10

  @doc """
  Processes a list of raw row maps from a CSV import.
  Returns a map of successful inserts and validation failures.
  """
  @spec process_rows(list(map())) :: map()
  def process_rows(rows) do
    {valid, invalid} =
      rows
      |> Enum.with_index(1)
      |> CollectionUtils.partition(fn {row, _idx} -> valid_row?(row) end)

    %{
      total: length(rows),
      valid_count: length(valid),
      invalid_count: length(invalid),
      valid_rows: Enum.map(valid, fn {row, idx} -> {idx, cleanse_row(row)} end),
      invalid_rows: Enum.map(invalid, fn {row, idx} ->
        {idx, %{row: row, errors: collect_errors(row)}}
      end)
    }
  end

  @doc """
  Cleanses a single row by trimming fields and normalising tag lists.
  """
  @spec cleanse_row(map()) :: map()
  def cleanse_row(row) do
    raw_tags = Map.get(row, "tags", [])

    cleaned_tags =
      raw_tags
      |> CollectionUtils.reject_blank()
      |> Enum.map(&String.downcase/1)
      |> CollectionUtils.deduplicate()
      |> Enum.take(@max_tags)

    row
    |> Map.update("email", "", &String.trim/1)
    |> Map.update("first_name", "", &String.trim/1)
    |> Map.update("last_name", "", &String.trim/1)
    |> Map.put("tags", cleaned_tags)
    |> Map.put("role", Map.get(row, "role", "member"))
  end

  defp valid_row?(row) do
    Enum.all?(@required_fields, fn field ->
      value = Map.get(row, field, "")
      is_binary(value) and String.trim(value) != ""
    end)
  end

  defp collect_errors(row) do
    Enum.flat_map(@required_fields, fn field ->
      value = Map.get(row, field, "")

      if not is_binary(value) or String.trim(value) == "" do
        ["#{field} is required and must not be blank"]
      else
        []
      end
    end)
  end
end
```
