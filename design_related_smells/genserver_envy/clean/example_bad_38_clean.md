```elixir
defmodule MyApp.ABTestingTask do
  @moduledoc """
  Manages A/B experiment assignment and result collection.
  Assigns users to variants, tracks exposure, and aggregates conversion events.
  """

  alias MyApp.{Repo, AnalyticsService}
  alias MyApp.Experiments.{Experiment, Assignment, ConversionEvent}

  @assignment_salt "ab_v1"

  def start_experiment_server(config) do
    Task.start_link(fn ->
      experiments =
        config.experiments
        |> Enum.into(%{}, fn exp -> {exp.id, %{exp | exposures: %{}, conversions: %{}}} end)

      state = %{
        config: config,
        experiments: experiments,
        user_assignments: %{}
      }

      experiment_loop(state)
    end)
  end

  defp experiment_loop(state) do
    receive do
      {:assign, from, experiment_id, user_id} ->
        case Map.fetch(state.experiments, experiment_id) do
          :error ->
            send(from, {:error, :experiment_not_found})
            experiment_loop(state)

          {:ok, %{status: :paused}} ->
            send(from, {:error, :experiment_paused})
            experiment_loop(state)

          {:ok, experiment} ->
            cached_key = {experiment_id, user_id}

            case Map.get(state.user_assignments, cached_key) do
              variant when not is_nil(variant) ->
                send(from, {:ok, variant})
                experiment_loop(state)

              nil ->
                variant = assign_variant(experiment, user_id)
                exposure_count = Map.get(experiment.exposures, variant, 0) + 1

                if experiment.max_exposures && exposure_count > experiment.max_exposures do
                  send(from, {:error, :exposure_cap_reached})
                  experiment_loop(state)
                else
                  updated_exp = %{
                    experiment
                    | exposures: Map.put(experiment.exposures, variant, exposure_count)
                  }

                  AnalyticsService.track(:experiment_exposure, %{
                    experiment_id: experiment_id,
                    variant: variant,
                    user_id: user_id
                  })

                  new_state = %{
                    state
                    | experiments: Map.put(state.experiments, experiment_id, updated_exp),
                      user_assignments: Map.put(state.user_assignments, cached_key, variant)
                  }

                  send(from, {:ok, variant})
                  experiment_loop(new_state)
                end
            end
        end

      {:record_conversion, from, experiment_id, user_id, event_name} ->
        case Map.fetch(state.experiments, experiment_id) do
          :error ->
            send(from, {:error, :experiment_not_found})
            experiment_loop(state)

          {:ok, experiment} ->
            variant = Map.get(state.user_assignments, {experiment_id, user_id})

            if is_nil(variant) do
              send(from, {:error, :no_assignment})
              experiment_loop(state)
            else
              conversion = %ConversionEvent{
                experiment_id: experiment_id,
                variant: variant,
                user_id: user_id,
                event_name: event_name,
                occurred_at: DateTime.utc_now()
              }

              Repo.insert!(conversion)
              conv_key = {variant, event_name}
              updated_conversions = Map.update(experiment.conversions, conv_key, 1, &(&1 + 1))
              updated_exp = %{experiment | conversions: updated_conversions}

              send(from, :ok)

              experiment_loop(%{
                state
                | experiments: Map.put(state.experiments, experiment_id, updated_exp)
              })
            end
        end

      {:pause, from, experiment_id} ->
        case Map.fetch(state.experiments, experiment_id) do
          :error ->
            send(from, {:error, :not_found})
            experiment_loop(state)

          {:ok, exp} ->
            updated = %{exp | status: :paused}
            send(from, :ok)
            experiment_loop(%{state | experiments: Map.put(state.experiments, experiment_id, updated)})
        end

      {:get_results, from, experiment_id} ->
        case Map.fetch(state.experiments, experiment_id) do
          :error ->
            send(from, {:error, :not_found})
            experiment_loop(state)

          {:ok, exp} ->
            results = %{
              experiment_id: experiment_id,
              exposures: exp.exposures,
              conversions: exp.conversions,
              status: exp.status
            }
            send(from, {:ok, results})
            experiment_loop(state)
        end

      :stop ->
        :ok
    end
  end

  defp assign_variant(experiment, user_id) do
    hash = :erlang.phash2({@assignment_salt, experiment.id, user_id}, 1_000)

    experiment.variants
    |> Enum.reduce_while(0, fn {variant, weight_pct}, acc ->
      bucket = acc + trunc(weight_pct * 10)
      if hash < bucket, do: {:halt, variant}, else: {:cont, bucket}
    end)
  end

  def assign(pid, experiment_id, user_id) do
    send(pid, {:assign, self(), experiment_id, user_id})

    receive do
      {:ok, variant} -> {:ok, variant}
      {:error, reason} -> {:error, reason}
    after
      3_000 -> {:error, :timeout}
    end
  end

  def record_conversion(pid, experiment_id, user_id, event_name) do
    send(pid, {:record_conversion, self(), experiment_id, user_id, event_name})

    receive do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    after
      3_000 -> {:error, :timeout}
    end
  end

  def get_results(pid, experiment_id) do
    send(pid, {:get_results, self(), experiment_id})

    receive do
      {:ok, results} -> {:ok, results}
      {:error, reason} -> {:error, reason}
    after
      5_000 -> {:error, :timeout}
    end
  end
end
```
