```elixir
defmodule Pipeline.DataEnricher do
  @moduledoc """
  A composable data enrichment pipeline for processing raw event records.

  Each enrichment stage is a named private function that transforms
  an intermediate result map. Stages are composed via `Enum.reduce/3`
  over a declared stage list, making it straightforward to add,
  remove, or reorder processing steps.
  """

  alias Pipeline.GeoResolver
  alias Pipeline.UserProfileCache
  alias Pipeline.CurrencyNormalizer

  @type raw_event :: %{
          required(:event_id) => String.t(),
          required(:user_id) => String.t(),
          required(:amount_raw) => String.t(),
          required(:currency_code) => String.t(),
          required(:ip_address) => String.t(),
          optional(atom()) => term()
        }

  @type enriched_event :: map()

  @stages [
    :normalize_amount,
    :resolve_geo,
    :attach_user_profile,
    :compute_risk_score
  ]

  @doc """
  Runs a raw event through all enrichment stages.

  Returns `{:ok, enriched_event}` when all stages complete, or
  `{:error, {stage, reason}}` if any stage fails.
  """
  @spec enrich(raw_event()) :: {:ok, enriched_event()} | {:error, {atom(), term()}}
  def enrich(%{event_id: _, user_id: _, amount_raw: _, currency_code: _, ip_address: _} = event) do
    initial = {:ok, event}

    Enum.reduce_while(@stages, initial, fn stage, {:ok, acc} ->
      case run_stage(stage, acc) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, {stage, reason}}}
      end
    end)
  end

  @spec run_stage(atom(), map()) :: {:ok, map()} | {:error, term()}
  defp run_stage(:normalize_amount, event) do
    normalize_amount(event)
  end

  defp run_stage(:resolve_geo, event) do
    resolve_geo(event)
  end

  defp run_stage(:attach_user_profile, event) do
    attach_user_profile(event)
  end

  defp run_stage(:compute_risk_score, event) do
    compute_risk_score(event)
  end

  @spec normalize_amount(map()) :: {:ok, map()} | {:error, :invalid_amount}
  defp normalize_amount(%{amount_raw: raw, currency_code: code} = event) do
    case CurrencyNormalizer.parse(raw, code) do
      {:ok, amount_cents} -> {:ok, Map.put(event, :amount_cents, amount_cents)}
      {:error, _} -> {:error, :invalid_amount}
    end
  end

  @spec resolve_geo(map()) :: {:ok, map()} | {:error, :geo_resolution_failed}
  defp resolve_geo(%{ip_address: ip} = event) do
    case GeoResolver.lookup(ip) do
      {:ok, %{country: _, region: _} = geo} -> {:ok, Map.put(event, :geo, geo)}
      {:error, _} -> {:error, :geo_resolution_failed}
    end
  end

  @spec attach_user_profile(map()) :: {:ok, map()} | {:error, :user_not_found}
  defp attach_user_profile(%{user_id: user_id} = event) do
    case UserProfileCache.fetch(user_id) do
      {:ok, profile} -> {:ok, Map.put(event, :user_profile, profile)}
      {:error, :not_found} -> {:error, :user_not_found}
    end
  end

  @spec compute_risk_score(map()) :: {:ok, map()}
  defp compute_risk_score(%{amount_cents: amount, user_profile: profile, geo: geo} = event) do
    score = calculate_score(amount, profile.account_age_days, geo.country)
    {:ok, Map.put(event, :risk_score, score)}
  end

  @spec calculate_score(non_neg_integer(), non_neg_integer(), String.t()) :: float()
  defp calculate_score(amount_cents, account_age_days, country) do
    base = amount_cents / 10_000
    age_factor = if account_age_days < 30, do: 1.5, else: 1.0
    geo_factor = if country in ["HighRiskCountry1", "HighRiskCountry2"], do: 1.3, else: 1.0
    Float.round(base * age_factor * geo_factor, 4)
  end
end
```
