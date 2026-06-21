```elixir
defmodule MyApp.Pipeline.DataEnricher do
  @moduledoc """
  Enriches a stream of raw event maps with contextual data fetched from
  multiple upstream services. Each enrichment step is a discrete function
  clause operating on a typed `EnrichedEvent` struct, making the pipeline
  easy to extend and test in isolation.

  Upstream lookups are batched per enrichment step using a single network
  call per batch rather than one call per event, keeping throughput high
  even at large batch sizes.
  """

  alias MyApp.Pipeline.EnrichedEvent
  alias MyApp.Accounts
  alias MyApp.Catalog
  alias MyApp.Geo

  @batch_size 100

  @type raw_event :: %{
          required(:event_id) => String.t(),
          required(:user_id) => String.t(),
          required(:product_id) => String.t(),
          required(:occurred_at) => DateTime.t(),
          optional(:ip_address) => String.t()
        }

  @doc """
  Enriches a list of raw events with user profiles, product details, and
  geo data derived from the originating IP address. Returns a list of
  `EnrichedEvent` structs in the same order as the input.
  """
  @spec enrich([raw_event()]) :: [EnrichedEvent.t()]
  def enrich(events) when is_list(events) do
    events
    |> Enum.chunk_every(@batch_size)
    |> Enum.flat_map(&enrich_batch/1)
  end

  @spec enrich_batch([raw_event()]) :: [EnrichedEvent.t()]
  defp enrich_batch(batch) do
    user_ids = Enum.map(batch, & &1.user_id)
    product_ids = Enum.map(batch, & &1.product_id)
    ip_addresses = batch |> Enum.map(&Map.get(&1, :ip_address)) |> Enum.reject(&is_nil/1)

    users = Accounts.fetch_many(user_ids)
    products = Catalog.fetch_many(product_ids)
    geo_data = Geo.lookup_many(ip_addresses)

    Enum.map(batch, fn event ->
      %EnrichedEvent{
        event_id: event.event_id,
        occurred_at: event.occurred_at,
        user: Map.get(users, event.user_id),
        product: Map.get(products, event.product_id),
        geo: Map.get(geo_data, Map.get(event, :ip_address))
      }
    end)
  end
end

defmodule MyApp.Pipeline.EnrichedEvent do
  @moduledoc "A raw event enriched with contextual domain data."

  @enforce_keys [:event_id, :occurred_at]
  defstruct [:event_id, :occurred_at, :user, :product, :geo]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          user: map() | nil,
          product: map() | nil,
          geo: map() | nil
        }

  @doc "Returns `true` when all enrichment fields were resolved successfully."
  @spec fully_enriched?(t()) :: boolean()
  def fully_enriched?(%__MODULE__{user: u, product: p, geo: g}),
    do: not is_nil(u) and not is_nil(p) and not is_nil(g)

  @doc "Returns a list of enrichment fields that are still missing."
  @spec missing_fields(t()) :: [atom()]
  def missing_fields(%__MODULE__{} = event) do
    [:user, :product, :geo]
    |> Enum.filter(fn field -> is_nil(Map.get(event, field)) end)
  end
end
```
