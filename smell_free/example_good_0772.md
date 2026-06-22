```elixir
defmodule Compliance.GDPRExporter do
  @moduledoc """
  Produces a GDPR data export package for a user. The export collects
  all personally identifiable data across registered domain modules,
  serialises it to JSON, and wraps it in a signed archive. Each domain
  module implements the `Compliance.DataSource` behaviour to contribute
  its records without coupling to this orchestrator.
  """

  require Logger

  alias Compliance.DataSource

  @type user_id :: String.t()
  @type export_package :: %{
          user_id: user_id(),
          exported_at: String.t(),
          sources: %{String.t() => term()},
          signature: String.t()
        }

  @type export_result :: {:ok, export_package()} | {:error, :no_data | :signing_failed}

  @doc """
  Exports all personal data for `user_id` from registered data sources.
  Returns a signed package map or an error.
  """
  @spec export(user_id()) :: export_result()
  def export(user_id) when is_binary(user_id) do
    sources = load_sources()
    data = collect_data(sources, user_id)

    if Enum.all?(Map.values(data), &Enum.empty?/1) do
      {:error, :no_data}
    else
      payload = %{
        user_id: user_id,
        exported_at: DateTime.to_iso8601(DateTime.utc_now()),
        sources: data
      }

      case sign_payload(payload) do
        {:ok, sig} -> {:ok, Map.put(payload, :signature, sig)}
        :error -> {:error, :signing_failed}
      end
    end
  end

  @doc "Returns the list of registered data source module names."
  @spec registered_sources() :: [module()]
  def registered_sources, do: load_sources()

  defp collect_data(sources, user_id) do
    Map.new(sources, fn mod ->
      key = mod |> Module.split() |> List.last() |> Macro.underscore()

      records =
        try do
          mod.export_for_user(user_id)
        rescue
          e ->
            Logger.warning("[GDPRExporter] #{inspect(mod)} raised: #{Exception.message(e)}")
            []
        end

      {key, records}
    end)
  end

  defp sign_payload(payload) do
    secret = Application.fetch_env!(:my_app, :gdpr_signing_key)
    json = Jason.encode!(payload)
    sig = :crypto.mac(:hmac, :sha256, secret, json) |> Base.encode16(case: :lower)
    {:ok, sig}
  rescue
    _ -> :error
  end

  defp load_sources do
    Application.get_env(:my_app, :gdpr_data_sources, [])
  end
end

defmodule Compliance.DataSource do
  @moduledoc "Behaviour for domain modules that contribute data to GDPR exports."

  @doc "Returns a list of maps representing the user's personal data records."
  @callback export_for_user(user_id :: String.t()) :: [map()]
end
```
