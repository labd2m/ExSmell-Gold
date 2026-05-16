# Example 42: Telematics GPS Route Scoring Service

```elixir
defmodule Telematics.RouteScorer do
  @moduledoc """
  Analyses GPS telemetry samples to score driver trips for insurance
  telematics, fleet safety programs, and eco-driving incentives.
  """

  alias Telematics.{Trip, Driver, TelemetrySample, ScoreRecord, Alert}

  @speed_limit_buffer_kmh 10
  @harsh_brake_threshold_g -0.4
  @harsh_accel_threshold_g 0.4
  @cornering_threshold_g 0.35

  def start_trip(driver_id, vehicle_id) do
    with {:ok, driver} <- Driver.get(driver_id) do
      trip = %Trip{
        id: generate_trip_id(),
        driver_id: driver_id,
        vehicle_id: vehicle_id,
        status: :in_progress,
        started_at: DateTime.utc_now()
      }

      {:ok, _} = Trip.insert(trip)
      {:ok, trip}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def score_trip(trip_id, driver_id, telemetry_samples) do
    with {:ok, trip} <- Trip.get(trip_id),
         {:ok, driver} <- Driver.get(driver_id),
         :ok <- validate_trip_ownership(trip, driver_id) do

      metrics = aggregate_metrics(telemetry_samples)

      speed_score = compute_speed_score(metrics)
      braking_score = compute_braking_score(metrics)
      acceleration_score = compute_acceleration_score(metrics)
      cornering_score = compute_cornering_score(metrics)

      overall_score =
        speed_score * 0.30 +
        braking_score * 0.30 +
        acceleration_score * 0.25 +
        cornering_score * 0.15

      score_record = %ScoreRecord{
        id: generate_score_id(),
        trip_id: trip_id,
        driver_id: driver_id,
        overall_score: Float.round(overall_score, 1),
        speed_score: Float.round(speed_score, 1),
        braking_score: Float.round(braking_score, 1),
        acceleration_score: Float.round(acceleration_score, 1),
        cornering_score: Float.round(cornering_score, 1),
        distance_km: metrics.total_distance_km,
        duration_minutes: metrics.duration_minutes,
        sample_count: length(telemetry_samples),
        scored_at: DateTime.utc_now()
      }

      {:ok, _} = ScoreRecord.insert(score_record)
      {:ok, _} = Trip.update(trip_id, %{status: :scored, score_id: score_record.id})

      if overall_score < 60.0 do
        issue_low_score_alert(driver, score_record)
      end

      {:ok, score_record}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def get_driver_score_summary(driver_id, days_back \\ 30) do
    cutoff = DateTime.add(DateTime.utc_now(), -days_back * 86_400, :second)

    with {:ok, driver} <- Driver.get(driver_id),
         {:ok, records} <- ScoreRecord.list_for_driver_since(driver_id, cutoff) do

      if Enum.empty?(records) do
        {:ok, %{driver_id: driver_id, message: :no_trips_in_period}}
      else
        avg_overall = average(Enum.map(records, & &1.overall_score))
        avg_speed = average(Enum.map(records, & &1.speed_score))
        avg_braking = average(Enum.map(records, & &1.braking_score))
        avg_accel = average(Enum.map(records, & &1.acceleration_score))
        total_km = Enum.sum(Enum.map(records, & &1.distance_km))

        summary = %{
          driver_id: driver_id,
          driver_name: driver.full_name,
          trip_count: length(records),
          total_distance_km: Float.round(total_km, 1),
          average_scores: %{
            overall: Float.round(avg_overall, 1),
            speed: Float.round(avg_speed, 1),
            braking: Float.round(avg_braking, 1),
            acceleration: Float.round(avg_accel, 1)
          },
          trend: compute_trend(records)
        }

        {:ok, summary}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def list_high_risk_drivers(fleet_id, threshold \\ 65.0) do
    with {:ok, drivers} <- Driver.list_for_fleet(fleet_id) do
      high_risk =
        drivers
        |> Enum.map(fn d ->
          case ScoreRecord.average_score_for_driver(d.id, days_back: 14) do
            {:ok, avg} when avg < threshold -> {:flag, d, avg}
            _ -> :skip
          end
        end)
        |> Enum.filter(&match?({:flag, _, _}, &1))
        |> Enum.map(fn {:flag, d, avg} -> %{driver_id: d.id, name: d.full_name, avg_score: avg} end)
        |> Enum.sort_by(& &1.avg_score)

      {:ok, high_risk}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp aggregate_metrics(samples) do
    count = length(samples)
    speeds = Enum.map(samples, & &1.speed_kmh)
    accel_values = Enum.map(samples, & &1.longitudinal_g)
    lateral_values = Enum.map(samples, & &1.lateral_g)

    %{
      avg_speed: Enum.sum(speeds) / count,
      max_speed: Enum.max(speeds),
      harsh_brake_events: Enum.count(accel_values, &(&1 < @harsh_brake_threshold_g)),
      harsh_accel_events: Enum.count(accel_values, &(&1 > @harsh_accel_threshold_g)),
      cornering_events: Enum.count(lateral_values, &(abs(&1) > @cornering_threshold_g)),
      total_distance_km: compute_distance(samples),
      duration_minutes: compute_duration(samples)
    }
  end

  defp compute_speed_score(%{max_speed: max, avg_speed: avg}) do
    speed_penalty = if max > 130, do: (max - 130) * 0.5, else: 0.0
    max(0, 100 - speed_penalty)
  end

  defp compute_braking_score(%{harsh_brake_events: events, duration_minutes: duration}) do
    rate = events / max(duration, 1) * 60
    max(0, 100 - rate * 15)
  end

  defp compute_acceleration_score(%{harsh_accel_events: events, duration_minutes: duration}) do
    rate = events / max(duration, 1) * 60
    max(0, 100 - rate * 12)
  end

  defp compute_cornering_score(%{cornering_events: events, duration_minutes: duration}) do
    rate = events / max(duration, 1) * 60
    max(0, 100 - rate * 10)
  end

  defp compute_distance(samples) do
    samples
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.sum_by(fn [a, b] -> haversine(a.lat, a.lng, b.lat, b.lng) end)
  end

  defp compute_duration([first | _] = samples) do
    last = List.last(samples)
    DateTime.diff(last.timestamp, first.timestamp, :second) / 60
  end

  defp haversine(lat1, lng1, lat2, lng2) do
    r = 6371
    dlat = (lat2 - lat1) * :math.pi() / 180
    dlng = (lng2 - lng1) * :math.pi() / 180
    a = :math.sin(dlat / 2) ** 2 + :math.cos(lat1 * :math.pi() / 180) * :math.cos(lat2 * :math.pi() / 180) * :math.sin(dlng / 2) ** 2
    r * 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
  end

  defp average(list), do: Enum.sum(list) / length(list)

  defp compute_trend(records) do
    sorted = Enum.sort_by(records, & &1.scored_at, DateTime)
    if length(sorted) < 2 do
      :insufficient_data
    else
      recent = sorted |> Enum.take(-5) |> average_score()
      older = sorted |> Enum.take(5) |> average_score()
      cond do
        recent > older + 3 -> :improving
        recent < older - 3 -> :declining
        true -> :stable
      end
    end
  end

  defp average_score(records), do: average(Enum.map(records, & &1.overall_score))

  defp validate_trip_ownership(%{driver_id: did}, did), do: :ok
  defp validate_trip_ownership(_, _), do: {:error, :trip_not_owned_by_driver}

  defp issue_low_score_alert(driver, score_record) do
    Alert.create(%{driver_id: driver.id, trip_id: score_record.trip_id, score: score_record.overall_score, alert_type: :low_trip_score})
  end

  defp generate_trip_id, do: "trip_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  defp generate_score_id, do: "scr_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
end
```
