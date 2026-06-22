```elixir
defmodule Healthcare.Records.ConsentManager do
  @moduledoc """
  Manages patient consent records for data sharing and treatment purposes.
  Consents are versioned and immutable once granted; revocation creates a new record.
  """

  alias Healthcare.Records.{Consent, ConsentRepository}

  @type grant_result :: {:ok, Consent.t()} | {:error, atom() | String.t()}

  @doc """
  Grants a new consent for `patient_id` covering `scope` from `grantor_id`.
  Returns `{:error, :duplicate}` if an active consent with the same scope exists.
  """
  @spec grant(String.t(), String.t(), atom(), keyword()) :: grant_result()
  def grant(patient_id, grantor_id, scope, opts \\ [])
      when is_binary(patient_id) and is_binary(grantor_id) and is_atom(scope) do
    repo = Keyword.get(opts, :repo, ConsentRepository)

    with :ok <- validate_scope(scope),
         :ok <- check_no_active_consent(patient_id, scope, repo),
         {:ok, consent} <- build_consent(patient_id, grantor_id, scope),
         {:ok, saved} <- repo.insert(consent) do
      {:ok, saved}
    end
  end

  @doc """
  Revokes an active consent record by ID.
  Returns `{:error, :not_found}` or `{:error, :already_revoked}` when ineligible.
  """
  @spec revoke(String.t(), String.t(), keyword()) :: {:ok, Consent.t()} | {:error, atom()}
  def revoke(consent_id, revoked_by, opts \\ [])
      when is_binary(consent_id) and is_binary(revoked_by) do
    repo = Keyword.get(opts, :repo, ConsentRepository)

    with {:ok, consent} <- repo.fetch(consent_id),
         :ok <- assert_active(consent),
         {:ok, revoked} <- repo.revoke(consent.id, revoked_by, DateTime.utc_now()) do
      {:ok, revoked}
    end
  end

  @doc """
  Returns whether an active consent for `scope` exists for `patient_id`.
  """
  @spec active?(String.t(), atom(), keyword()) :: boolean()
  def active?(patient_id, scope, opts \\ [])
      when is_binary(patient_id) and is_atom(scope) do
    repo = Keyword.get(opts, :repo, ConsentRepository)

    case repo.fetch_active(patient_id, scope) do
      {:ok, _} -> true
      {:error, :not_found} -> false
    end
  end

  @supported_scopes ~w(treatment data_sharing research marketing)a

  defp validate_scope(scope) when scope in @supported_scopes, do: :ok
  defp validate_scope(scope), do: {:error, "unsupported consent scope: #{inspect(scope)}"}

  defp check_no_active_consent(patient_id, scope, repo) do
    case repo.fetch_active(patient_id, scope) do
      {:error, :not_found} -> :ok
      {:ok, _} -> {:error, :duplicate}
    end
  end

  defp build_consent(patient_id, grantor_id, scope) do
    consent = %Consent{
      id: Ecto.UUID.generate(),
      patient_id: patient_id,
      grantor_id: grantor_id,
      scope: scope,
      status: :active,
      granted_at: DateTime.utc_now(),
      revoked_at: nil,
      revoked_by: nil
    }

    {:ok, consent}
  end

  defp assert_active(%Consent{status: :active}), do: :ok
  defp assert_active(%Consent{status: :revoked}), do: {:error, :already_revoked}
end
```
