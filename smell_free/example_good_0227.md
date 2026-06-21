```elixir
defmodule MyApp.Experiments.ABAssignment do
  @moduledoc """
  Assigns users deterministically to experiment variants using a
  hash-based allocation strategy. The same user always receives the same
  variant for a given experiment, without requiring any persistent state
  or external coordination. Variant weights are expressed as integer
  percentages that must sum to 100.

  Experiments are defined as module attributes so that the allocation
  logic is testable without a running database or process.
  """

  @experiments %{
    "checkout_v2" => [
      %{name: "control", weight: 50},
      %{name: "streamlined", weight: 30},
      %{name: "one_page", weight: 20}
    ],
    "homepage_hero" => [
      %{name: "image_left", weight: 50},
      %{name: "image_right", weight: 50}
    ],
    "pricing_display" => [
      %{name: "monthly_first", weight: 33},
      %{name: "annual_first", weight: 33},
      %{name: "comparison_table", weight: 34}
    ]
  }

  @type user_id :: String.t()
  @type experiment_name :: String.t()
  @type variant_name :: String.t()

  @doc """
  Returns the variant name assigned to `user_id` in `experiment_name`.
  Returns `{:error, :unknown_experiment}` when the experiment is not defined.
  The assignment is stable: the same user always receives the same variant.
  """
  @spec assign(user_id(), experiment_name()) ::
          {:ok, variant_name()} | {:error, :unknown_experiment}
  def assign(user_id, experiment_name)
      when is_binary(user_id) and is_binary(experiment_name) do
    case Map.fetch(@experiments, experiment_name) do
      {:ok, variants} ->
        bucket = hash_bucket(user_id, experiment_name)
        {:ok, pick_variant(variants, bucket)}

      :error ->
        {:error, :unknown_experiment}
    end
  end

  @doc "Returns a list of all defined experiment names."
  @spec experiment_names() :: [experiment_name()]
  def experiment_names, do: Map.keys(@experiments)

  @doc """
  Returns the full variant configuration for `experiment_name`,
  or `{:error, :unknown_experiment}`.
  """
  @spec variants(experiment_name()) :: {:ok, [map()]} | {:error, :unknown_experiment}
  def variants(experiment_name) when is_binary(experiment_name) do
    Map.fetch(@experiments, experiment_name)
    |> case do
      {:ok, _} = ok -> ok
      :error -> {:error, :unknown_experiment}
    end
  end

  @spec hash_bucket(user_id(), experiment_name()) :: non_neg_integer()
  defp hash_bucket(user_id, experiment_name) do
    seed = "#{experiment_name}:#{user_id}"

    :crypto.hash(:sha256, seed)
    |> binary_part(0, 4)
    |> :binary.decode_unsigned()
    |> rem(100)
  end

  @spec pick_variant([map()], non_neg_integer()) :: variant_name()
  defp pick_variant(variants, bucket) do
    {variant, _} =
      Enum.reduce_while(variants, {nil, 0}, fn
        %{name: name, weight: weight}, {_, cumulative} ->
          new_cumulative = cumulative + weight

          if bucket < new_cumulative do
            {:halt, {name, new_cumulative}}
          else
            {:cont, {nil, new_cumulative}}
          end
      end)

    variant || List.last(variants).name
  end
end
```
