```elixir
defmodule Pipeline.DataEnricher do
  @moduledoc """
  A composable enrichment pipeline for raw event records.
  Each enrichment step is an independent function that returns
  `{:ok, enriched}` or `{:error, reason}`, enabling transparent failure isolation.
  """

  alias Pipeline.{GeoResolver, DeviceParser, UserProfileCache}

  @type raw_event :: %{
          ip_address: String.t(),
          user_agent: String.t(),
          user_id: String.t(),
          payload: map()
        }

  @type enriched_event :: map()

  @spec enrich(raw_event()) :: {:ok, enriched_event()} | {:error, atom()}
  def enrich(raw_event) do
    with {:ok, geo} <- GeoResolver.resolve(raw_event.ip_address),
         {:ok, device} <- DeviceParser.parse(raw_event.user_agent),
         {:ok, profile} <- UserProfileCache.fetch(raw_event.user_id) do
      {:ok, build_enriched(raw_event, geo, device, profile)}
    end
  end

  @spec enrich_batch([raw_event()]) :: %{ok: [enriched_event()], error: [map()]}
  def enrich_batch(events) when is_list(events) do
    Enum.reduce(events, %{ok: [], error: []}, fn event, acc ->
      case enrich(event) do
        {:ok, enriched} -> Map.update!(acc, :ok, &[enriched | &1])
        {:error, reason} -> Map.update!(acc, :error, &[%{event: event, reason: reason} | &1])
      end
    end)
  end

  @spec build_enriched(raw_event(), map(), map(), map()) :: enriched_event()
  defp build_enriched(event, geo, device, profile) do
    %{
      user_id: event.user_id,
      payload: event.payload,
      geo: %{
        country: geo.country_code,
        region: geo.region,
        city: geo.city
      },
      device: %{
        type: device.type,
        os: device.os,
        browser: device.browser
      },
      user: %{
        tier: profile.subscription_tier,
        locale: profile.locale,
        created_at: profile.inserted_at
      }
    }
  end
end
```
