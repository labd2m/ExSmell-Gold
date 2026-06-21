```elixir
defmodule MapDiff.Change do
  @moduledoc """
  A single typed change between two versions of a nested map.
  """

  @type kind :: :added | :removed | :changed

  @type t :: %__MODULE__{
          kind: kind(),
          path: [term()],
          old_value: term(),
          new_value: term()
        }

  defstruct [:kind, :path, :old_value, :new_value]

  @spec added([term()], term()) :: t()
  def added(path, value), do: %__MODULE__{kind: :added, path: path, old_value: nil, new_value: value}

  @spec removed([term()], term()) :: t()
  def removed(path, value), do: %__MODULE__{kind: :removed, path: path, old_value: value, new_value: nil}

  @spec changed([term()], term(), term()) :: t()
  def changed(path, old, new), do: %__MODULE__{kind: :changed, path: path, old_value: old, new_value: new}
end

defmodule MapDiff do
  @moduledoc """
  Recursively computes the structural difference between two maps.

  Changes are represented as a flat list of `MapDiff.Change` structs, each
  carrying the full key path from the root, the change kind, and the old
  and new values. Nested maps are diffed recursively; non-map values that
  differ produce a `:changed` entry at their path depth.
  """

  alias MapDiff.Change

  @spec diff(map(), map()) :: [Change.t()]
  def diff(old, new) when is_map(old) and is_map(new) do
    diff_maps(old, new, [])
  end

  @spec added?(Change.t()) :: boolean()
  def added?(%Change{kind: :added}), do: true
  def added?(_), do: false

  @spec removed?(Change.t()) :: boolean()
  def removed?(%Change{kind: :removed}), do: true
  def removed?(_), do: false

  @spec changed?(Change.t()) :: boolean()
  def changed?(%Change{kind: :changed}), do: true
  def changed?(_), do: false

  @spec filter_by_path([Change.t()], [term()]) :: [Change.t()]
  def filter_by_path(changes, prefix) when is_list(prefix) do
    Enum.filter(changes, fn %Change{path: path} ->
      List.starts_with?(path, prefix)
    end)
  end

  @spec summary([Change.t()]) :: %{added: non_neg_integer(), removed: non_neg_integer(), changed: non_neg_integer()}
  def summary(changes) do
    Enum.reduce(changes, %{added: 0, removed: 0, changed: 0}, fn change, acc ->
      Map.update!(acc, change.kind, &(&1 + 1))
    end)
  end

  defp diff_maps(old, new, path) do
    all_keys = MapSet.union(MapSet.new(Map.keys(old)), MapSet.new(Map.keys(new)))

    Enum.flat_map(all_keys, fn key ->
      key_path = path ++ [key]

      case {Map.fetch(old, key), Map.fetch(new, key)} do
        {:error, {:ok, new_val}} ->
          [Change.added(key_path, new_val)]

        {{:ok, old_val}, :error} ->
          [Change.removed(key_path, old_val)]

        {{:ok, old_val}, {:ok, new_val}} when is_map(old_val) and is_map(new_val) ->
          diff_maps(old_val, new_val, key_path)

        {{:ok, old_val}, {:ok, new_val}} when old_val == new_val ->
          []

        {{:ok, old_val}, {:ok, new_val}} ->
          [Change.changed(key_path, old_val, new_val)]
      end
    end)
  end
end
```
