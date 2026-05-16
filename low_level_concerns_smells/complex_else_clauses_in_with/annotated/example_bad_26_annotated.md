# Annotated Bad Example 26

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `activate_license/3`, inside the `with` block's `else` clause
- **Affected function(s):** `activate_license/3`
- **Short explanation:** License activation chains five operations—validating the license key, checking the seat quota, verifying the activating machine, applying feature entitlements, and writing the activation record. All failure modes from these steps are collapsed into one `else` block, stripping away any indication of which step produced a given error.

```elixir
defmodule Licensing.ActivationService do
  alias Licensing.{Repo, License, Activation, Machine, EntitlementEngine, NotificationService}

  require Logger

  def activate_license(license_key, machine_fingerprint, user_id) do
    with {:ok, license} <- fetch_valid_license(license_key),
         :ok <- check_seat_availability(license),
         {:ok, machine} <- resolve_machine(machine_fingerprint, user_id),
         {:ok, entitlements} <- EntitlementEngine.resolve(license),
         {:ok, activation} <- persist_activation(license, machine, user_id, entitlements) do
      NotificationService.send_activation_receipt(user_id, license, activation)

      Logger.info(
        "License #{license.id} activated: user=#{user_id} machine=#{machine.id} " <>
          "features=#{inspect(entitlements.features)}"
      )

      {:ok, %{
        activation_id: activation.id,
        features: entitlements.features,
        expires_at: license.expires_at
      }}
    else
      # VALIDATION: SMELL START - Complex else clauses in with
      # VALIDATION: This is a smell because five independent steps each produce different
      # error shapes, all caught in one `else` block. `:invalid_key`, `:license_expired`,
      # and `:license_revoked` come from license fetching; `:seat_limit_reached` from
      # seat quota checking; `:machine_blocked` from machine verification;
      # `{:entitlement_error, _}` from entitlement resolution; and `:activation_db_error`
      # from persistence — with no structural grouping in the `else` block.
      {:error, :invalid_key} ->
        Logger.warning("Invalid license key used by user #{user_id}")
        {:error, :license_key_invalid}

      {:error, :license_expired} ->
        Logger.warning("Expired license key used by user #{user_id}: #{license_key}")
        {:error, :license_expired}

      {:error, :license_revoked} ->
        Logger.warning("Revoked license key used by user #{user_id}: #{license_key}")
        {:error, :license_revoked}

      {:error, :seat_limit_reached} ->
        Logger.warning("Seat limit reached for license #{license_key}")
        {:error, :no_seats_available}

      {:error, :machine_blocked} ->
        Logger.warning(
          "Machine fingerprint #{machine_fingerprint} is blocked from activating licenses"
        )
        {:error, :machine_not_allowed}

      {:error, {:entitlement_error, reason}} ->
        Logger.error("Entitlement resolution failed: #{inspect(reason)}")
        {:error, :entitlement_configuration_error}

      {:error, :activation_db_error} ->
        Logger.error("Activation record could not be persisted for license #{license_key}")
        {:error, :persistence_failed}
      # VALIDATION: SMELL END
    end
  end

  defp fetch_valid_license(key) do
    case Repo.get_by(License, key: key) do
      nil ->
        {:error, :invalid_key}

      %License{status: :revoked} ->
        {:error, :license_revoked}

      %License{expires_at: exp} = license when not is_nil(exp) ->
        if DateTime.compare(DateTime.utc_now(), exp) == :gt do
          {:error, :license_expired}
        else
          {:ok, license}
        end

      license ->
        {:ok, license}
    end
  end

  defp check_seat_availability(%License{max_seats: max, id: license_id}) do
    used =
      Repo.aggregate(
        from(a in Activation, where: a.license_id == ^license_id and a.status == :active),
        :count
      )

    if used < max, do: :ok, else: {:error, :seat_limit_reached}
  end

  defp resolve_machine(fingerprint, user_id) do
    case Repo.get_by(Machine, fingerprint: fingerprint) do
      %Machine{blocked: true} ->
        {:error, :machine_blocked}

      nil ->
        %Machine{}
        |> Machine.changeset(%{fingerprint: fingerprint, registered_by: user_id})
        |> Repo.insert()

      machine ->
        {:ok, machine}
    end
  end

  defp persist_activation(license, machine, user_id, entitlements) do
    %Activation{}
    |> Activation.changeset(%{
      license_id: license.id,
      machine_id: machine.id,
      user_id: user_id,
      features: entitlements.features,
      activated_at: DateTime.utc_now(),
      status: :active
    })
    |> Repo.insert()
    |> case do
      {:ok, a} -> {:ok, a}
      {:error, _} -> {:error, :activation_db_error}
    end
  end
end
```
