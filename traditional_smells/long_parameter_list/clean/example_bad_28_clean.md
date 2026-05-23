```elixir
defmodule Analytics.Events do
  @moduledoc """
  Tracks product analytics events, enriches them with geo/device context,
  and forwards them to the data pipeline.
  """

  require Logger

  alias Analytics.Repo
  alias Analytics.Schemas.Event
  alias Analytics.GeoEnricher
  alias Analytics.Pipeline

  @valid_platforms ~w(web ios android desktop)
  @valid_categories ~w(engagement commerce support navigation error)
  @max_property_keys 30

  def track(
        user_id,
        session_id,
        ip_address,
        event_name,
        category,
        source,
        platform,
        app_version,
        properties
      ) do
    with :ok <- validate_event_name(event_name),
         :ok <- validate_category(category),
         :ok <- validate_platform(platform),
         :ok <- validate_properties(properties) do
      geo = GeoEnricher.lookup(ip_address)

      event_attrs = %{
        user_id: user_id,
        session_id: session_id,
        ip_address: ip_address,
        event_name: event_name,
        category: category,
        source: source,
        platform: platform,
        app_version: app_version,
        properties: properties,
        country: geo[:country],
        region: geo[:region],
        city: geo[:city],
        occurred_at: DateTime.utc_now()
      }

      case Repo.insert(Event.changeset(%Event{}, event_attrs)) do
        {:ok, event} ->
          Pipeline.publish(:events, %{
            id: event.id,
            name: event_name,
            user_id: user_id,
            category: category,
            platform: platform,
            occurred_at: event.occurred_at
          })

          Logger.debug("Event #{event_name} tracked for user #{user_id}")
          {:ok, event}

        {:error, changeset} ->
          Logger.error("Event tracking failed: #{inspect(changeset.errors)}")
          {:error, :tracking_failed}
      end
    end
  end

  defp validate_event_name(name) do
    if is_binary(name) and Regex.match?(~r/^[a-z][a-z0-9_.]{1,63}$/, name) do
      :ok
    else
      {:error, :invalid_event_name}
    end
  end

  defp validate_category(c) when c in @valid_categories, do: :ok
  defp validate_category(c), do: {:error, {:unknown_category, c}}

  defp validate_platform(p) when p in @valid_platforms, do: :ok
  defp validate_platform(p), do: {:error, {:unknown_platform, p}}

  defp validate_properties(nil), do: :ok

  defp validate_properties(props) when is_map(props) do
    if map_size(props) <= @max_property_keys do
      :ok
    else
      {:error, :too_many_properties}
    end
  end

  defp validate_properties(_), do: {:error, :properties_must_be_map}
end
```
