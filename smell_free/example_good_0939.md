```elixir
defmodule Config.Change do
  @moduledoc false

  @type kind :: :added | :removed | :modified

  @type t :: %__MODULE__{
          kind: kind(),
          path: String.t(),
          old_value: term(),
          new_value: term()
        }

  defstruct [:kind, :path, :old_value, :new_value]

  @spec added(String.t(), term()) :: t()
  def added(path, value), do: %__MODULE__{kind: :added, path: path, new_value: value, old_value: nil}

  @spec removed(String.t(), term()) :: t()
  def removed(path, value), do: %__MODULE__{kind: :removed, path: path, old_value: value, new_value: nil}

  @spec modified(String.t(), term(), term()) :: t()
  def modified(path, old, new), do: %__MODULE__{kind: :modified, path: path, old_value: old, new_value: new}
end

defmodule Config.Differ do
  @moduledoc """
  Computes a typed diff between two configuration snapshots.

  Keys are compared recursively; nested maps are traversed and changes
  are reported with dot-separated path strings such as `"database.pool_size"`.
  List and scalar values that differ produce a single `:modified` entry at
  their path depth rather than element-wise diffing. All changes are
  collected before returning, giving operators a complete picture of what
  changed between two configuration versions.
  """

  alias Config.Change

  @type snapshot :: map()
  @type diff_result :: %{
          added: [Change.t()],
          removed: [Change.t()],
          modified: [Change.t()],
          unchanged: non_neg_integer()
        }

  @spec diff(snapshot(), snapshot()) :: diff_result()
  def diff(before_config, after_config)
      when is_map(before_config) and is_map(after_config) do
    changes = compute(before_config, after_config, "")

    %{
      added: Enum.filter(changes, &(&1.kind == :added)),
      removed: Enum.filter(changes, &(&1.kind == :removed)),
      modified: Enum.filter(changes, &(&1.kind == :modified)),
      unchanged: count_unchanged(before_config, after_config)
    }
  end

  @spec changed?(snapshot(), snapshot()) :: boolean()
  def changed?(before_config, after_config) do
    result = diff(before_config, after_config)
    result.added != [] or result.removed != [] or result.modified != []
  end

  @spec format(diff_result()) :: [String.t()]
  def format(%{added: added, removed: removed, modified: modified}) do
    removed_lines = Enum.map(removed, &"  - #{&1.path}: #{inspect(&1.old_value)}")
    added_lines = Enum.map(added, &"  + #{&1.path}: #{inspect(&1.new_value)}")
    modified_lines = Enum.map(modified, &"  ~ #{&1.path}: #{inspect(&1.old_value)} → #{inspect(&1.new_value)}")
    removed_lines ++ modified_lines ++ added_lines
  end

  defp compute(before_map, after_map, prefix) when is_map(before_map) and is_map(after_map) do
    all_keys = MapSet.union(MapSet.new(Map.keys(before_map)), MapSet.new(Map.keys(after_map)))

    Enum.flat_map(all_keys, fn key ->
      path = build_path(prefix, key)

      case {Map.fetch(before_map, key), Map.fetch(after_map, key)} do
        {:error, {:ok, new_val}} ->
          [Change.added(path, new_val)]

        {{:ok, old_val}, :error} ->
          [Change.removed(path, old_val)]

        {{:ok, old_val}, {:ok, new_val}} when is_map(old_val) and is_map(new_val) ->
          compute(old_val, new_val, path)

        {{:ok, old_val}, {:ok, new_val}} when old_val == new_val ->
          []

        {{:ok, old_val}, {:ok, new_val}} ->
          [Change.modified(path, old_val, new_val)]
      end
    end)
  end

  defp count_unchanged(before_map, after_map) do
    Enum.count(before_map, fn {key, value} ->
      Map.get(after_map, key) == value
    end)
  end

  defp build_path("", key), do: to_string(key)
  defp build_path(prefix, key), do: "#{prefix}.#{key}"
end
```
