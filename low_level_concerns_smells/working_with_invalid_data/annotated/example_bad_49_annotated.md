# Example 49: IoT Sensor Threshold Alert Engine - Annotated

## Metadata
- **Smell Name**: Working with invalid data
- **Expected Location**: `IoT.AlertEngine.evaluate_reading/3` function
- **Affected Functions**: `evaluate_reading/3`
- **Explanation**: The function does not validate that `reading_value` is a number before comparing it against numeric threshold bounds. Passing a string or binary will cause a confusing `ArgumentError` or `BadArg` inside the comparison operators rather than a clear boundary validation error.

## Code

```elixir
defmodule IoT.AlertEngine do
  @moduledoc """
  Evaluates incoming sensor readings against configurable alert thresholds,
  manages alert lifecycle, and dispatches notifications for the IoT monitoring platform.
  """

  alias IoT.{Device, Sensor, Reading, AlertRule, Alert, NotificationChannel, AuditLog}

  @alert_cooldown_seconds 300
  @critical_escalation_minutes 15

  def register_alert_rule(device_id, sensor_type, rule_params) do
    with {:ok, device} <- Device.get(device_id),
         :ok <- validate_sensor_type(sensor_type),
         :ok <- validate_rule_params(rule_params) do

      rule = %AlertRule{
        id: generate_rule_id(),
        device_id: device_id,
        sensor_type: sensor_type,
        condition: rule_params.condition,
        threshold_low: rule_params[:threshold_low],
        threshold_high: rule_params[:threshold_high],
        severity: rule_params.severity,
        notification_channels: rule_params.notification_channels,
        cooldown_seconds: rule_params[:cooldown_seconds] || @alert_cooldown_seconds,
        enabled: true,
        created_at: DateTime.utc_now()
      }

      {:ok, _} = AlertRule.insert(rule)
      {:ok, rule}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # VALIDATION: SMELL START - Working with invalid data
  # VALIDATION: This is a smell because `reading_value` is not validated to be a
  # VALIDATION: numeric type before being compared against `rule.threshold_low` and
  # VALIDATION: `rule.threshold_high` inside `threshold_breached?/2`.
  # VALIDATION: A string like "87.3" from a misbehaving sensor adapter will cause
  # VALIDATION: an ArgumentError deep inside the comparison rather than a clear
  # VALIDATION: validation error at this public function's entry point.
  def evaluate_reading(device_id, sensor_type, reading_value) do
    with {:ok, device} <- Device.get(device_id),
         {:ok, rules} <- AlertRule.list_enabled_for_sensor(device_id, sensor_type) do

      reading = %Reading{
        id: generate_reading_id(),
        device_id: device_id,
        sensor_type: sensor_type,
        # No type validation on reading_value before storage or comparison
        value: reading_value,
        recorded_at: DateTime.utc_now()
      }

      {:ok, _} = Reading.insert(reading)

      triggered_alerts =
        rules
        |> Enum.filter(fn rule -> threshold_breached?(rule, reading_value) end)
        |> Enum.filter(fn rule -> not in_cooldown?(rule, device_id) end)
        |> Enum.map(fn rule -> create_and_dispatch_alert(device, reading, rule) end)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, alert} -> alert end)

      {:ok, %{reading_id: reading.id, alerts_triggered: length(triggered_alerts), alerts: triggered_alerts}}
    else
      {:error, reason} -> {:error, reason}
    end
  end
  # VALIDATION: SMELL END

  def acknowledge_alert(alert_id, acknowledged_by, notes \\ nil) do
    with {:ok, alert} <- Alert.get(alert_id),
         :ok <- validate_alert_acknowledgeable(alert) do

      {:ok, _} = Alert.update(alert_id, %{
        status: :acknowledged,
        acknowledged_by: acknowledged_by,
        acknowledged_at: DateTime.utc_now(),
        notes: notes
      })

      {:ok, :acknowledged}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_alert(alert_id, resolved_by, resolution_notes) do
    with {:ok, alert} <- Alert.get(alert_id),
         :ok <- validate_alert_resolvable(alert) do

      {:ok, _} = Alert.update(alert_id, %{
        status: :resolved,
        resolved_by: resolved_by,
        resolved_at: DateTime.utc_now(),
        resolution_notes: resolution_notes
      })

      {:ok, _} = AuditLog.record(:alert_resolved, resolved_by, %{alert_id: alert_id})

      {:ok, :resolved}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def list_active_alerts(device_id, opts \\ []) do
    severity = Keyword.get(opts, :severity)
    sensor_type = Keyword.get(opts, :sensor_type)

    with {:ok, alerts} <- Alert.list_active_for_device(device_id, severity: severity, sensor_type: sensor_type) do
      enriched =
        Enum.map(alerts, fn alert ->
          age_minutes = DateTime.diff(DateTime.utc_now(), alert.triggered_at, :second) / 60

          alert
          |> Map.put(:age_minutes, Float.round(age_minutes, 1))
          |> Map.put(:escalated, age_minutes > @critical_escalation_minutes and alert.severity == :critical)
        end)

      {:ok, enriched}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def get_device_health_summary(device_id) do
    with {:ok, device} <- Device.get(device_id),
         {:ok, recent_readings} <- Reading.list_recent_for_device(device_id, limit: 100),
         {:ok, active_alerts} <- Alert.list_active_for_device(device_id) do

      by_sensor =
        recent_readings
        |> Enum.group_by(& &1.sensor_type)
        |> Enum.map(fn {sensor_type, readings} ->
          values = Enum.map(readings, & &1.value)
          {sensor_type, %{
            latest: List.first(values),
            min: Enum.min(values),
            max: Enum.max(values),
            avg: Float.round(Enum.sum(values) / length(values), 2),
            reading_count: length(readings)
          }}
        end)
        |> Map.new()

      {:ok, %{
        device_id: device_id,
        device_name: device.name,
        device_status: device.status,
        active_alert_count: length(active_alerts),
        critical_alerts: Enum.count(active_alerts, &(&1.severity == :critical)),
        sensor_summary: by_sensor,
        last_seen: device.last_seen_at
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp threshold_breached?(%{condition: :above, threshold_high: high}, value), do: value > high
  defp threshold_breached?(%{condition: :below, threshold_low: low}, value), do: value < low
  defp threshold_breached?(%{condition: :outside, threshold_low: low, threshold_high: high}, value) do
    value < low or value > high
  end
  defp threshold_breached?(%{condition: :between, threshold_low: low, threshold_high: high}, value) do
    value >= low and value <= high
  end

  defp in_cooldown?(rule, device_id) do
    case Alert.most_recent_for_rule(rule.id, device_id) do
      {:ok, nil} -> false
      {:ok, last_alert} ->
        seconds_since = DateTime.diff(DateTime.utc_now(), last_alert.triggered_at, :second)
        seconds_since < rule.cooldown_seconds
      _ -> false
    end
  end

  defp create_and_dispatch_alert(device, reading, rule) do
    alert = %Alert{
      id: generate_alert_id(),
      device_id: device.id,
      rule_id: rule.id,
      sensor_type: reading.sensor_type,
      reading_id: reading.id,
      reading_value: reading.value,
      severity: rule.severity,
      status: :active,
      triggered_at: DateTime.utc_now()
    }

    with {:ok, saved_alert} <- Alert.insert(alert) do
      Enum.each(rule.notification_channels, fn channel ->
        NotificationChannel.dispatch(channel, saved_alert, device)
      end)

      {:ok, saved_alert}
    end
  end

  defp validate_sensor_type(type) when type in [:temperature, :humidity, :pressure, :co2, :motion, :vibration, :current], do: :ok
  defp validate_sensor_type(_), do: {:error, :unsupported_sensor_type}

  defp validate_rule_params(%{condition: c, severity: s} = params)
       when c in [:above, :below, :outside, :between] and s in [:info, :warning, :critical] do
    cond do
      c in [:outside, :between] and (is_nil(params[:threshold_low]) or is_nil(params[:threshold_high])) ->
        {:error, :missing_threshold_bounds}
      c == :above and is_nil(params[:threshold_high]) ->
        {:error, :missing_threshold_high}
      c == :below and is_nil(params[:threshold_low]) ->
        {:error, :missing_threshold_low}
      true -> :ok
    end
  end

  defp validate_rule_params(_), do: {:error, :invalid_rule_params}

  defp validate_alert_acknowledgeable(%{status: :active}), do: :ok
  defp validate_alert_acknowledgeable(_), do: {:error, :alert_not_acknowledgeable}

  defp validate_alert_resolvable(%{status: status}) when status in [:active, :acknowledged], do: :ok
  defp validate_alert_resolvable(_), do: {:error, :alert_not_resolvable}

  defp generate_rule_id, do: "rule_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  defp generate_reading_id, do: "rdg_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  defp generate_alert_id, do: "alert_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
end
```
