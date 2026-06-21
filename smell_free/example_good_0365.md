```elixir
defmodule Pipelines.DataEnrichmentWorker do
  @moduledoc """
  Supervised GenServer that enriches raw contact records by calling a
  sequence of enrichment provider modules. Providers are tried in priority
  order; the first successful response wins. Failed providers are skipped
  and logged rather than retried immediately. The enriched record is
  persisted once all providers have been attempted.
  """

  use GenServer

  require Logger

  alias Pipelines.EnrichmentProvider

  @type contact :: %{id: String.t(), email: String.t()}
  @type enriched_data :: map()
  @type provider_module :: module()

  @doc "Starts an enrichment worker for a single contact."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    contact = Keyword.fetch!(opts, :contact)
    providers = Keyword.get(opts, :providers, default_providers())
    send(self(), :run)
    {:ok, %{contact: contact, providers: providers}}
  end

  @impl GenServer
  def handle_info(:run, state) do
    enriched = run_enrichment(state.contact, state.providers)
    persist(state.contact, enriched)
    {:stop, :normal, state}
  end

  defp run_enrichment(contact, providers) do
    Enum.reduce(providers, %{}, fn mod, acc ->
      case safe_enrich(mod, contact) do
        {:ok, data} when is_map(data) ->
          Map.merge(acc, data)

        {:error, reason} ->
          Logger.warning("[EnrichmentWorker] #{mod} failed for #{contact.id}: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp safe_enrich(mod, contact) do
    mod.enrich(contact)
  rescue
    e -> {:error, {:provider_crashed, Exception.message(e)}}
  end

  defp persist(contact, enriched_data) when map_size(enriched_data) == 0 do
    Logger.info("[EnrichmentWorker] No enrichment data for #{contact.id}, skipping write")
  end

  defp persist(contact, enriched_data) do
    case MyApp.Repo.update_all(
           {Pipelines.Contact, id: contact.id},
           set: [enriched_data: enriched_data, enriched_at: DateTime.utc_now()]
         ) do
      {1, _} -> Logger.info("[EnrichmentWorker] Enriched contact #{contact.id}")
      _ -> Logger.warning("[EnrichmentWorker] Contact #{contact.id} not found during persist")
    end
  end

  defp default_providers do
    Application.get_env(:my_app, :enrichment_providers, [])
  end
end

defmodule Pipelines.EnrichmentProvider do
  @moduledoc "Behaviour for contact data enrichment provider modules."

  @doc "Enriches the given contact map with additional data fields."
  @callback enrich(contact :: map()) :: {:ok, map()} | {:error, term()}
end
```
