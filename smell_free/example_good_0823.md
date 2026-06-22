```elixir
defmodule Seed.Entry do
  @moduledoc false

  @type t :: %__MODULE__{
          name: atom(),
          depends_on: [atom()],
          data: [map()],
          schema: module(),
          unique_by: [atom()]
        }

  defstruct [:name, :schema, :data, depends_on: [], unique_by: [:id]]
end

defmodule Seed.Loader do
  @moduledoc """
  Loads declarative seed data into the database idempotently and in
  dependency order.

  Seeds are declared as `Entry` structs listing the schema, a list of
  record maps, and the fields that determine uniqueness. Existing records
  matching the unique key are skipped; new records are inserted.
  Entries are sorted topologically so a seed that depends on another
  always runs after its prerequisite, regardless of declaration order.
  """

  alias Seed.Entry

  @type result :: %{
          name: atom(),
          inserted: non_neg_integer(),
          skipped: non_neg_integer()
        }

  @spec run([Entry.t()], module()) :: {:ok, [result()]} | {:error, term()}
  def run(entries, repo) when is_list(entries) and is_atom(repo) do
    case sort_by_dependency(entries) do
      {:ok, ordered} ->
        results = Enum.map(ordered, &load_entry(&1, repo))
        {:ok, results}

      {:error, _} = err ->
        err
    end
  end

  defp load_entry(%Entry{schema: schema, data: data, unique_by: unique_by, name: name}, repo) do
    {inserted, skipped} =
      Enum.reduce(data, {0, 0}, fn record, {ins, skip} ->
        unique_filter = Map.take(record, unique_by)

        if repo.get_by(schema, unique_filter) do
          {ins, skip + 1}
        else
          repo.insert!(struct(schema, record))
          {ins + 1, skip}
        end
      end)

    %{name: name, inserted: inserted, skipped: skipped}
  end

  defp sort_by_dependency(entries) do
    name_map = Map.new(entries, &{&1.name, &1})
    ordered = topo_sort(Map.keys(name_map), name_map, [], MapSet.new())

    case ordered do
      {:ok, names} -> {:ok, Enum.map(names, &name_map[&1])}
      {:error, _} = err -> err
    end
  end

  defp topo_sort([], _map, acc, _visited), do: {:ok, Enum.reverse(acc)}

  defp topo_sort([name | rest], map, acc, visited) do
    if MapSet.member?(visited, name) do
      topo_sort(rest, map, acc, visited)
    else
      entry = Map.fetch!(map, name)
      unresolved = Enum.reject(entry.depends_on, &MapSet.member?(visited, &1))

      if unresolved != [] do
        topo_sort(unresolved ++ [name | rest], map, acc, visited)
      else
        topo_sort(rest, map, [name | acc], MapSet.put(visited, name))
      end
    end
  end
end

defmodule Seed.Reporter do
  @moduledoc false

  require Logger

  @spec log([Seed.Loader.result()]) :: :ok
  def log(results) when is_list(results) do
    total_inserted = Enum.sum(Enum.map(results, & &1.inserted))
    total_skipped = Enum.sum(Enum.map(results, & &1.skipped))

    Enum.each(results, fn %{name: name, inserted: ins, skipped: skip} ->
      Logger.info("Seed #{name}: #{ins} inserted, #{skip} skipped")
    end)

    Logger.info("Seed complete: #{total_inserted} total inserted, #{total_skipped} total skipped")
  end
end
```
