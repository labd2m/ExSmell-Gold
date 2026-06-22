# File: `example_good_816.md`

```elixir
defmodule Notifications.DigestBuilder do
  @moduledoc """
  Aggregates individual notifications into grouped digest summaries
  suitable for batched delivery (e.g. daily or weekly email digests).

  Notifications are grouped by category and deduplicated by a configurable
  key function so a single digest does not surface the same event twice.
  Each group is summarised with a headline count and a configurable
  number of representative examples.
  """

  @type category :: atom()
  @type notification_id :: String.t()

  @type notification :: %{
          required(:id) => notification_id(),
          required(:category) => category(),
          required(:title) => String.t(),
          required(:body) => String.t(),
          required(:occurred_at) => DateTime.t()
        }

  @type digest_group :: %{
          category: category(),
          count: pos_integer(),
          examples: [notification()],
          oldest_at: DateTime.t(),
          newest_at: DateTime.t()
        }

  @type digest :: %{
          total_count: non_neg_integer(),
          group_count: non_neg_integer(),
          groups: [digest_group()],
          period_start: DateTime.t(),
          period_end: DateTime.t()
        }

  @type build_opts :: [
          max_examples_per_group: pos_integer(),
          dedup_key_fn: (notification() -> term()),
          sort_groups_by: :count | :newest | :category
        ]

  @doc """
  Builds a digest from a list of notifications.

  Options:
  - `:max_examples_per_group` — examples shown per category (default: 3)
  - `:dedup_key_fn` — function returning a deduplication key per notification
  - `:sort_groups_by` — `:count`, `:newest`, or `:category` (default: `:count`)

  Returns a `digest` with groups sorted according to `:sort_groups_by`.
  """
  @spec build([notification()], build_opts()) :: digest()
  def build(notifications, opts \\ []) when is_list(notifications) do
    max_examples = Keyword.get(opts, :max_examples_per_group, 3)
    dedup_key_fn = Keyword.get(opts, :dedup_key_fn, & &1.id)
    sort_by = Keyword.get(opts, :sort_groups_by, :count)

    deduplicated = deduplicate(notifications, dedup_key_fn)
    groups = group_by_category(deduplicated, max_examples)
    sorted = sort_groups(groups, sort_by)

    {period_start, period_end} = period_bounds(deduplicated)

    %{
      total_count: length(deduplicated),
      group_count: length(sorted),
      groups: sorted,
      period_start: period_start,
      period_end: period_end
    }
  end

  @doc """
  Filters a digest to only groups matching `categories`.
  """
  @spec filter_categories(digest(), [category()]) :: digest()
  def filter_categories(%{groups: groups} = digest, categories) when is_list(categories) do
    allowed = MapSet.new(categories)
    filtered_groups = Enum.filter(groups, &MapSet.member?(allowed, &1.category))
    total = Enum.sum(Enum.map(filtered_groups, & &1.count))
    %{digest | groups: filtered_groups, group_count: length(filtered_groups), total_count: total}
  end

  @doc """
  Returns `true` when the digest is empty (no notifications).
  """
  @spec empty?(digest()) :: boolean()
  def empty?(%{total_count: 0}), do: true
  def empty?(%{}), do: false

  @doc """
  Merges two digests covering the same user, combining their groups
  and deduplicating across the boundary.
  """
  @spec merge(digest(), digest()) :: digest()
  def merge(%{groups: groups_a} = a, %{groups: groups_b}) do
    all_groups =
      (groups_a ++ groups_b)
      |> Enum.group_by(& &1.category)
      |> Enum.map(fn {category, groups} -> merge_groups(category, groups) end)
      |> Enum.sort_by(& &1.count, :desc)

    period_start = Enum.min_by([a.period_start, a.period_end], &DateTime.to_unix/1)

    %{
      total_count: Enum.sum(Enum.map(all_groups, & &1.count)),
      group_count: length(all_groups),
      groups: all_groups,
      period_start: period_start,
      period_end: DateTime.utc_now()
    }
  end

  defp deduplicate(notifications, dedup_key_fn) do
    notifications
    |> Enum.uniq_by(dedup_key_fn)
    |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
  end

  defp group_by_category(notifications, max_examples) do
    notifications
    |> Enum.group_by(& &1.category)
    |> Enum.map(fn {category, items} ->
      sorted = Enum.sort_by(items, & &1.occurred_at, {:desc, DateTime})
      %{
        category: category,
        count: length(items),
        examples: Enum.take(sorted, max_examples),
        oldest_at: List.last(sorted).occurred_at,
        newest_at: List.first(sorted).occurred_at
      }
    end)
  end

  defp sort_groups(groups, :count), do: Enum.sort_by(groups, & &1.count, :desc)
  defp sort_groups(groups, :newest), do: Enum.sort_by(groups, & &1.newest_at, {:desc, DateTime})
  defp sort_groups(groups, :category), do: Enum.sort_by(groups, & Atom.to_string(&1.category))

  defp period_bounds([]), do: {DateTime.utc_now(), DateTime.utc_now()}

  defp period_bounds(notifications) do
    oldest = Enum.min_by(notifications, & &1.occurred_at, DateTime)
    newest = Enum.max_by(notifications, & &1.occurred_at, DateTime)
    {oldest.occurred_at, newest.occurred_at}
  end

  defp merge_groups(category, groups) do
    all_examples = Enum.flat_map(groups, & &1.examples)
    total = Enum.sum(Enum.map(groups, & &1.count))
    sorted = Enum.sort_by(all_examples, & &1.occurred_at, {:desc, DateTime})
    oldest = Enum.min_by(sorted, & &1.occurred_at, DateTime)
    newest = Enum.max_by(sorted, & &1.occurred_at, DateTime)
    %{category: category, count: total, examples: Enum.take(sorted, 3),
      oldest_at: oldest.occurred_at, newest_at: newest.occurred_at}
  end
end
```
