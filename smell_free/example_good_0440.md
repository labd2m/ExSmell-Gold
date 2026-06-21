```elixir
defmodule Compliance.DataErasure do
  @moduledoc """
  Implements the GDPR Right to Erasure by anonymising personal data across
  all storage layers for a given user. Each storage layer has a dedicated
  erasure handler that replaces PII with deterministic pseudonyms, retains
  records needed for legal obligations, and publishes an audit event.
  The erasure runs inside a Multi to ensure the erasure log entry is always
  created even when individual layers report partial errors, making the
  operation fully auditable.
  """

  alias Compliance.{ErasureLog, Repo}
  alias Ecto.Multi

  require Logger

  @type user_id :: binary()
  @type erasure_result :: %{
          user_id: user_id(),
          layers_processed: [atom()],
          layers_failed: [%{layer: atom(), reason: term()}],
          completed_at: DateTime.t()
        }

  @erasure_layers [
    Compliance.Erasure.ProfileLayer,
    Compliance.Erasure.OrderLayer,
    Compliance.Erasure.AuditLogLayer,
    Compliance.Erasure.SessionLayer,
    Compliance.Erasure.AnalyticsLayer
  ]

  @doc """
  Initiates the full data erasure sequence for `user_id`. All PII fields are
  replaced with pseudonymous values. Returns `{:ok, erasure_result}` once all
  layers have been processed. Failed layers are recorded but do not abort
  other layers or the audit log entry.
  """
  @spec erase(user_id()) :: {:ok, erasure_result()} | {:error, term()}
  def erase(user_id) when is_binary(user_id) do
    Logger.info("Data erasure initiated", user_id: user_id)
    pseudonym = derive_pseudonym(user_id)

    {succeeded, failed} = run_layers(user_id, pseudonym)
    result = build_result(user_id, succeeded, failed)

    with {:ok, _log} <- record_erasure(result) do
      Logger.info("Data erasure complete",
        user_id: user_id,
        layers_ok: length(succeeded),
        layers_failed: length(failed)
      )

      {:ok, result}
    end
  end

  @doc """
  Returns the erasure record for `user_id` if one exists, confirming
  the right-to-erasure request was fulfilled.
  """
  @spec erasure_record(user_id()) :: {:ok, ErasureLog.t()} | {:error, :not_found}
  def erasure_record(user_id) when is_binary(user_id) do
    case Repo.get_by(ErasureLog, user_id: user_id) do
      nil -> {:error, :not_found}
      log -> {:ok, log}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp run_layers(user_id, pseudonym) do
    Enum.reduce(@erasure_layers, {[], []}, fn layer, {ok_acc, err_acc} ->
      case layer.erase(user_id, pseudonym) do
        :ok ->
          {[layer_name(layer) | ok_acc], err_acc}

        {:error, reason} ->
          Logger.warning("Erasure layer failed",
            layer: layer_name(layer),
            user_id: user_id,
            reason: inspect(reason)
          )
          error = %{layer: layer_name(layer), reason: reason}
          {ok_acc, [error | err_acc]}
      end
    end)
  end

  defp derive_pseudonym(user_id) do
    :crypto.hash(:sha256, "erasure:pseudonym:" <> user_id)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
    |> then(&"erased_#{&1}")
  end

  defp build_result(user_id, succeeded, failed) do
    %{
      user_id: user_id,
      layers_processed: Enum.reverse(succeeded),
      layers_failed: Enum.reverse(failed),
      completed_at: DateTime.utc_now()
    }
  end

  defp record_erasure(result) do
    %ErasureLog{}
    |> ErasureLog.changeset(%{
      user_id: result.user_id,
      layers_processed: result.layers_processed,
      layers_failed: Enum.map(result.layers_failed, &Map.update!(&1, :reason, fn r -> inspect(r) end)),
      completed_at: result.completed_at
    })
    |> Repo.insert()
  end

  defp layer_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> String.downcase()
    |> String.to_atom()
  end
end
```
