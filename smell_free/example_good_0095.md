# File: `example_good_95.md`

```elixir
defmodule DataSync.ConflictResolver do
  @moduledoc """
  Resolves concurrent write conflicts between a local record version and
  one or more remote versions using a configurable resolution strategy.

  All resolution logic is pure; no database access occurs here. The
  caller is responsible for persisting the resolved record.
  """

  @type version :: pos_integer()
  @type timestamp :: DateTime.t()
  @type record :: map()

  @type versioned_record :: %{
          required(:id) => String.t(),
          required(:version) => version(),
          required(:updated_at) => timestamp(),
          required(:data) => record()
        }

  @type strategy :: :last_write_wins | :highest_version | {:field_merge, [atom()]}

  @type resolution :: %{
          winner: versioned_record(),
          losers: [versioned_record()],
          strategy_used: strategy(),
          conflict_detected: boolean()
        }

  @doc """
  Resolves a conflict between a local record and a list of remote versions.

  Strategies:
  - `:last_write_wins` — selects the record with the most recent `updated_at`
  - `:highest_version` — selects the record with the greatest `version` number
  - `{:field_merge, fields}` — builds a merged record using each named field
    from the version where it was most recently changed

  Returns a `resolution` describing the outcome and all losing versions.
  """
  @spec resolve(versioned_record(), [versioned_record()], strategy()) :: resolution()
  def resolve(%{} = local, remotes, strategy)
      when is_list(remotes) do
    all_versions = [local | remotes]

    {winner, losers} = apply_strategy(all_versions, strategy)

    %{
      winner: winner,
      losers: losers,
      strategy_used: strategy,
      conflict_detected: length(remotes) > 0
    }
  end

  @doc """
  Returns `true` when two versioned records represent a genuine conflict,
  meaning they have the same ID but diverging versions originating from
  the same base version.
  """
  @spec conflict?(versioned_record(), versioned_record()) :: boolean()
  def conflict?(%{id: id, version: v1}, %{id: id, version: v2}) do
    v1 != v2
  end

  def conflict?(_a, _b), do: false

  defp apply_strategy(versions, :last_write_wins) do
    sorted = Enum.sort_by(versions, & &1.updated_at, {:desc, DateTime})
    pick_winner(sorted)
  end

  defp apply_strategy(versions, :highest_version) do
    sorted = Enum.sort_by(versions, & &1.version, :desc)
    pick_winner(sorted)
  end

  defp apply_strategy(versions, {:field_merge, fields}) do
    merged_data = merge_fields(versions, fields)

    best_version = Enum.max_by(versions, & &1.version)
    latest_timestamp = Enum.max_by(versions, & &1.updated_at, DateTime)

    winner = %{
      best_version
      | data: merged_data,
        version: best_version.version + 1,
        updated_at: latest_timestamp.updated_at
    }

    {winner, versions}
  end

  defp pick_winner([winner | losers]), do: {winner, losers}

  defp merge_fields(versions, fields) do
    Enum.reduce(fields, %{}, fn field, merged ->
      best_value = pick_best_field_value(versions, field)
      Map.put(merged, field, best_value)
    end)
  end

  defp pick_best_field_value(versions, field) do
    versions
    |> Enum.filter(fn v -> Map.has_key?(v.data, field) end)
    |> Enum.max_by(& &1.updated_at, DateTime, fn -> nil end)
    |> case do
      nil -> nil
      version -> Map.get(version.data, field)
    end
  end

  @doc """
  Produces a human-readable diff summary between two record data maps,
  listing fields that changed and their before/after values.
  """
  @spec diff(record(), record()) :: [%{field: atom(), before: term(), after: term()}]
  def diff(before_data, after_data)
      when is_map(before_data) and is_map(after_data) do
    all_keys =
      (Map.keys(before_data) ++ Map.keys(after_data))
      |> Enum.uniq()

    Enum.flat_map(all_keys, fn key ->
      before_val = Map.get(before_data, key)
      after_val = Map.get(after_data, key)

      if before_val == after_val do
        []
      else
        [%{field: key, before: before_val, after: after_val}]
      end
    end)
  end
end
```
