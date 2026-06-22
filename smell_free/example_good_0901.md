# File: `example_good_901.md`

```elixir
defmodule Workflow.ChecklistRunner do
  @moduledoc """
  Executes an ordered checklist of items where each item may declare
  prerequisite items that must be completed before it can run.

  Items are executed in topological order derived from their
  prerequisite graph. Parallel execution is supported for items whose
  prerequisites are all satisfied. The runner collects outcomes for
  every item rather than stopping at the first failure.
  """

  @type item_id :: atom()
  @type check_fn :: (-> :pass | :fail | {:fail, String.t()})

  @type checklist_item :: %{
          required(:id) => item_id(),
          required(:name) => String.t(),
          required(:check) => check_fn(),
          optional(:requires) => [item_id()]
        }

  @type item_outcome :: %{
          id: item_id(),
          name: String.t(),
          result: :pass | :fail | :skipped,
          detail: String.t() | nil,
          duration_ms: non_neg_integer()
        }

  @type run_result :: %{
          status: :passed | :failed,
          outcomes: [item_outcome()],
          passed_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          skipped_count: non_neg_integer()
        }

  @doc """
  Runs all items in `checklist` respecting their prerequisite ordering.

  Items whose prerequisites failed or were skipped are themselves skipped
  rather than run. Returns a `run_result` with outcomes for every item.
  """
  @spec run([checklist_item()]) :: run_result()
  def run(checklist) when is_list(checklist) do
    ordered = topological_sort(checklist)
    outcomes = execute_in_order(ordered)
    summarise(outcomes)
  end

  @doc """
  Returns the execution order that `run/1` would use for a checklist,
  without actually running the checks. Useful for previewing the plan.
  """
  @spec execution_order([checklist_item()]) ::
          {:ok, [item_id()]} | {:error, {:cycle, [item_id()]}}
  def execution_order(checklist) when is_list(checklist) do
    case try_topological_sort(checklist) do
      {:ok, sorted} -> {:ok, Enum.map(sorted, & &1.id)}
      {:error, _} = error -> error
    end
  end

  defp topological_sort(checklist) do
    case try_topological_sort(checklist) do
      {:ok, sorted} -> sorted
      {:error, {:cycle, ids}} -> raise "Checklist cycle detected: #{inspect(ids)}"
    end
  end

  defp try_topological_sort(checklist) do
    by_id = Map.new(checklist, &{&1.id, &1})
    in_degrees = Map.new(checklist, fn item -> {item.id, length(Map.get(item, :requires, []))} end)
    deps_map = Map.new(checklist, fn item -> {item.id, Map.get(item, :requires, [])} end)

    reverse_deps =
      Enum.reduce(checklist, %{}, fn item, acc ->
        Enum.reduce(Map.get(item, :requires, []), acc, fn dep, inner ->
          Map.update(inner, dep, [item.id], &[item.id | &1])
        end)
      end)

    queue = for {id, 0} <- in_degrees, do: id

    case kahn(queue, in_degrees, reverse_deps, by_id, []) do
      {:ok, sorted} when length(sorted) == length(checklist) -> {:ok, Enum.reverse(sorted)}
      {:ok, sorted} ->
        completed = MapSet.new(sorted, & &1.id)
        cycle_members = Enum.map(checklist, & &1.id) |> Enum.reject(&MapSet.member?(completed, &1))
        {:error, {:cycle, cycle_members}}
    end
  end

  defp kahn([], _degrees, _rev_deps, _by_id, acc), do: {:ok, acc}

  defp kahn([id | rest], degrees, rev_deps, by_id, acc) do
    item = Map.fetch!(by_id, id)
    successors = Map.get(rev_deps, id, [])

    {new_queue, new_degrees} =
      Enum.reduce(successors, {rest, degrees}, fn succ, {q, d} ->
        new_deg = Map.get(d, succ, 0) - 1
        updated_d = Map.put(d, succ, new_deg)
        if new_deg == 0, do: {q ++ [succ], updated_d}, else: {q, updated_d}
      end)

    kahn(new_queue, new_degrees, rev_deps, by_id, [item | acc])
  end

  defp execute_in_order(items) do
    Enum.reduce(items, {%{}, []}, fn item, {results, outcomes} ->
      requires = Map.get(item, :requires, [])
      all_passed = Enum.all?(requires, &(Map.get(results, &1) == :pass))

      outcome =
        if all_passed do
          run_item(item)
        else
          %{id: item.id, name: item.name, result: :skipped, detail: "prerequisite not met", duration_ms: 0}
        end

      new_results = Map.put(results, item.id, outcome.result)
      {new_results, [outcome | outcomes]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp run_item(item) do
    start_ms = System.monotonic_time(:millisecond)

    {result, detail} =
      try do
        case item.check.() do
          :pass -> {:pass, nil}
          :fail -> {:fail, "check returned :fail"}
          {:fail, msg} -> {:fail, msg}
        end
      rescue
        e -> {:fail, "raised: #{Exception.message(e)}"}
      end

    %{id: item.id, name: item.name, result: result, detail: detail,
      duration_ms: System.monotonic_time(:millisecond) - start_ms}
  end

  defp summarise(outcomes) do
    passed = Enum.count(outcomes, &(&1.result == :pass))
    failed = Enum.count(outcomes, &(&1.result == :fail))
    skipped = Enum.count(outcomes, &(&1.result == :skipped))

    %{
      status: if(failed == 0, do: :passed, else: :failed),
      outcomes: outcomes,
      passed_count: passed,
      failed_count: failed,
      skipped_count: skipped
    }
  end
end
```
