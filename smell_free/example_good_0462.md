```elixir
defmodule MyApp.Experiments.VariantTracker do
  @moduledoc """
  Records experiment variant exposures for users and aggregates
  conversion events against each variant. Tracking is fire-and-forget
  via async writes so that experiment instrumentation adds zero latency
  to the user-facing request path.

  Conversion counts and exposure counts are queried from the
  `experiment_events` table via SQL aggregation, keeping the read path
  independent of any in-process state.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Experiments.ExperimentEvent

  import Ecto.Query, warn: false

  @type experiment_name :: String.t()
  @type variant_name :: String.t()
  @type user_id :: String.t()

  @type variant_stats :: %{
          variant: variant_name(),
          exposures: non_neg_integer(),
          conversions: non_neg_integer(),
          conversion_rate: float()
        }

  @doc """
  Records that `user_id` was exposed to `variant` in `experiment`.
  Writes asynchronously; the calling process is never blocked.
  """
  @spec track_exposure(experiment_name(), variant_name(), user_id()) :: :ok
  def track_exposure(experiment, variant, user_id)
      when is_binary(experiment) and is_binary(variant) and is_binary(user_id) do
    Task.start(fn ->
      insert_event(experiment, variant, user_id, :exposure)
    end)

    :ok
  end

  @doc """
  Records a conversion event for `user_id` within `experiment`.
  Only meaningful when the user has a prior recorded exposure.
  """
  @spec track_conversion(experiment_name(), variant_name(), user_id()) :: :ok
  def track_conversion(experiment, variant, user_id)
      when is_binary(experiment) and is_binary(variant) and is_binary(user_id) do
    Task.start(fn ->
      insert_event(experiment, variant, user_id, :conversion)
    end)

    :ok
  end

  @doc """
  Returns aggregated exposure and conversion stats per variant for
  `experiment`. Results are sorted by exposure count descending.
  """
  @spec stats(experiment_name()) :: [variant_stats()]
  def stats(experiment) when is_binary(experiment) do
    ExperimentEvent
    |> where([e], e.experiment == ^experiment)
    |> group_by([e], e.variant)
    |> select([e], %{
      variant: e.variant,
      exposures: filter(count(e.id), e.event_type == :exposure),
      conversions: filter(count(e.id), e.event_type == :conversion)
    })
    |> order_by([e], desc: filter(count(e.id), e.event_type == :exposure))
    |> Repo.all()
    |> Enum.map(&attach_conversion_rate/1)
  end

  @doc """
  Returns the variant with the highest conversion rate for `experiment`,
  or `nil` when no data is available.
  """
  @spec winning_variant(experiment_name()) :: variant_stats() | nil
  def winning_variant(experiment) when is_binary(experiment) do
    experiment
    |> stats()
    |> Enum.filter(&(&1.exposures >= 100))
    |> Enum.max_by(& &1.conversion_rate, fn -> nil end)
  end

  @spec insert_event(experiment_name(), variant_name(), user_id(), atom()) :: :ok
  defp insert_event(experiment, variant, user_id, event_type) do
    %ExperimentEvent{}
    |> ExperimentEvent.changeset(%{
      experiment: experiment,
      variant: variant,
      user_id: user_id,
      event_type: event_type,
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert()

    :ok
  rescue
    e ->
      Logger.warning("experiment_event_insert_failed",
        experiment: experiment,
        error: Exception.message(e)
      )
  end

  @spec attach_conversion_rate(map()) :: variant_stats()
  defp attach_conversion_rate(%{exposures: 0} = stats) do
    Map.put(stats, :conversion_rate, 0.0)
  end

  defp attach_conversion_rate(stats) do
    rate = Float.round(stats.conversions / stats.exposures * 100, 2)
    Map.put(stats, :conversion_rate, rate)
  end
end
```
