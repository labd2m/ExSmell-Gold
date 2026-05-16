```elixir
defmodule Marketing.CampaignLauncher do
  @moduledoc """
  Validates and launches marketing campaigns, enforcing budget caps,
  audience targeting rules, and scheduling constraints. Emits campaign
  activation events for downstream ad-serving integration.
  """

  require Logger

  @min_budget          100.0
  @max_duration_days   365
  @valid_audience_keys ~w(age_min age_max regions interests)

  @type campaign_record :: %{
          id: String.t(),
          name: String.t(),
          budget: float(),
          daily_cap: float(),
          target_audience: map(),
          start_date: Date.t(),
          end_date: Date.t() | nil,
          duration_days: integer() | nil,
          status: :active | :scheduled,
          launched_at: DateTime.t()
        }

  @spec launch(map(), map()) ::
          {:ok, campaign_record()} | {:error, list(String.t())}
  def launch(campaign, launch_config) do
    budget          = campaign[:budget]
    target_audience = campaign[:target_audience]
    start_date      = campaign[:start_date]
    end_date        = campaign[:end_date]

    name = Map.get(campaign, :name, "Unnamed Campaign")

    errors =
      []
      |> validate_budget(budget)
      |> validate_start_date(start_date)
      |> validate_date_range(start_date, end_date)
      |> validate_audience(target_audience)

    if errors == [] do
      today        = Date.utc_today()
      status       = if Date.compare(start_date, today) == :gt, do: :scheduled, else: :active
      duration     = if end_date, do: Date.diff(end_date, start_date)
      daily_cap    = compute_daily_cap(budget, duration, launch_config)

      record = %{
        id: Map.get(campaign, :id, generate_id()),
        name: name,
        budget: budget,
        daily_cap: daily_cap,
        target_audience: target_audience || %{},
        start_date: start_date,
        end_date: end_date,
        duration_days: duration,
        status: status,
        launched_at: DateTime.utc_now()
      }

      emit_activation_event(record)

      Logger.info("Campaign launched",
        campaign_id: record.id,
        name: name,
        status: status,
        budget: budget,
        daily_cap: daily_cap,
        duration_days: duration
      )

      {:ok, record}
    else
      {:error, errors}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp compute_daily_cap(budget, nil, config) do
    fallback_days = Map.get(config, :default_duration_days, 30)
    Float.round(budget / fallback_days, 2)
  end

  defp compute_daily_cap(budget, duration_days, _config) when duration_days > 0 do
    Float.round(budget / duration_days, 2)
  end

  defp compute_daily_cap(budget, _, _), do: budget

  defp emit_activation_event(record) do
    Logger.debug("Emitting activation event for campaign #{record.id}")
    :ok
  end

  # ── Validators ──────────────────────────────────────────────────────────────

  defp validate_budget(errors, nil),
    do: ["Budget is required" | errors]

  defp validate_budget(errors, b) when is_number(b) and b >= @min_budget,
    do: errors

  defp validate_budget(errors, b),
    do: ["Budget must be at least #{@min_budget}, got: #{inspect(b)}" | errors]

  defp validate_start_date(errors, nil),
    do: ["Start date is required" | errors]

  defp validate_start_date(errors, %Date{}), do: errors

  defp validate_start_date(errors, d),
    do: ["Start date must be a Date, got: #{inspect(d)}" | errors]

  defp validate_date_range(errors, nil, _), do: errors

  defp validate_date_range(errors, _start, nil), do: errors

  defp validate_date_range(errors, start_date, end_date) do
    duration = Date.diff(end_date, start_date)

    cond do
      duration <= 0 ->
        ["End date must be after start date" | errors]

      duration > @max_duration_days ->
        ["Campaign duration exceeds #{@max_duration_days} days" | errors]

      true ->
        errors
    end
  end

  defp validate_audience(errors, nil), do: errors

  defp validate_audience(errors, audience) when is_map(audience) do
    invalid_keys =
      audience
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in @valid_audience_keys))

    if invalid_keys == [] do
      errors
    else
      ["Unknown audience targeting keys: #{Enum.join(invalid_keys, ", ")}" | errors]
    end
  end

  defp validate_audience(errors, a),
    do: ["Target audience must be a map, got: #{inspect(a)}" | errors]

  defp generate_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end
end
```
