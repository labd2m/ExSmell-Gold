```elixir
defmodule Webhooks.SigningKeyRotation do
  @moduledoc """
  Manages zero-downtime rotation of HMAC signing keys for outbound webhooks.
  During rotation a new key is generated and stored alongside the current key.
  Outbound signatures are computed with the new key immediately; inbound
  signature verification accepts both the current and the previous key for a
  configurable grace period, giving subscribers time to update their stored
  secrets before the old key is retired. The rotation lifecycle progresses
  through `:active -> :rotating -> :retired` states tracked in the database.
  """

  alias Webhooks.{Endpoint, SigningKey, Repo}
  alias Ecto.Multi

  require Logger

  @type endpoint_id :: binary()
  @type key_state :: :active | :rotating | :retired
  @grace_period_seconds 7 * 24 * 60 * 60

  @doc """
  Initiates key rotation for `endpoint_id`. Generates a fresh secret and
  transitions the current key to `:rotating` status. Returns the new key
  so the caller can surface it to the subscriber.
  """
  @spec initiate(endpoint_id()) :: {:ok, %{new_secret: binary()}} | {:error, term()}
  def initiate(endpoint_id) when is_binary(endpoint_id) do
    with {:ok, endpoint} <- fetch_endpoint(endpoint_id),
         {:ok, current_key} <- fetch_active_key(endpoint_id),
         {:ok, new_secret, new_key} <- create_new_key(endpoint_id) do
      Multi.new()
      |> Multi.update(:retire_current, SigningKey.transition_changeset(current_key, :rotating))
      |> Multi.update(:activate_new, SigningKey.transition_changeset(new_key, :active))
      |> Repo.transaction()
      |> case do
        {:ok, _} ->
          Logger.info("Webhook key rotation initiated",
            endpoint_id: endpoint_id,
            new_key_id: new_key.id
          )

          {:ok, %{new_secret: new_secret}}

        {:error, _step, reason, _} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Verifies `signature` against the request `body` for `endpoint_id`.
  Accepts signatures computed with either the active key or any key in
  `:rotating` state that has not yet exceeded the grace period.
  Returns `:ok` or `{:error, :invalid_signature}`.
  """
  @spec verify_inbound(endpoint_id(), binary(), binary()) ::
          :ok | {:error, :invalid_signature | :no_active_key}
  def verify_inbound(endpoint_id, body, signature)
      when is_binary(endpoint_id) and is_binary(body) and is_binary(signature) do
    keys = load_verification_keys(endpoint_id)

    if Enum.empty?(keys) do
      {:error, :no_active_key}
    else
      valid = Enum.any?(keys, fn key -> check_hmac(body, signature, key.secret) end)
      if valid, do: :ok, else: {:error, :invalid_signature}
    end
  end

  @doc """
  Signs `body` with the currently active key for `endpoint_id`.
  Returns `{:ok, signature}` or `{:error, :no_active_key}`.
  """
  @spec sign_outbound(endpoint_id(), binary()) ::
          {:ok, binary()} | {:error, :no_active_key}
  def sign_outbound(endpoint_id, body) when is_binary(endpoint_id) and is_binary(body) do
    case fetch_active_key(endpoint_id) do
      {:ok, key} ->
        sig =
          :crypto.mac(:hmac, :sha256, key.secret, body)
          |> Base.encode16(case: :lower)

        {:ok, "sha256=#{sig}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Retires all `:rotating` keys whose grace period has elapsed.
  Returns the count of keys retired. Run periodically via an Oban cron job.
  """
  @spec retire_expired_keys() :: {:ok, non_neg_integer()}
  def retire_expired_keys do
    cutoff = DateTime.add(DateTime.utc_now(), -@grace_period_seconds, :second)

    {count, _} =
      Repo.update_all(
        from(k in SigningKey,
          where: k.state == :rotating and k.transitioned_at < ^cutoff
        ),
        set: [state: :retired, updated_at: DateTime.utc_now()]
      )

    Logger.info("Retired expired webhook signing keys", count: count)
    {:ok, count}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_endpoint(endpoint_id) do
    case Repo.get(Endpoint, endpoint_id) do
      nil -> {:error, :endpoint_not_found}
      ep -> {:ok, ep}
    end
  end

  defp fetch_active_key(endpoint_id) do
    case Repo.get_by(SigningKey, endpoint_id: endpoint_id, state: :active) do
      nil -> {:error, :no_active_key}
      key -> {:ok, key}
    end
  end

  defp create_new_key(endpoint_id) do
    secret = :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)

    changeset =
      SigningKey.changeset(%SigningKey{}, %{
        endpoint_id: endpoint_id,
        secret: secret,
        state: :rotating
      })

    case Repo.insert(changeset) do
      {:ok, key} -> {:ok, secret, key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_verification_keys(endpoint_id) do
    grace_cutoff = DateTime.add(DateTime.utc_now(), -@grace_period_seconds, :second)

    Repo.all(
      from(k in SigningKey,
        where: k.endpoint_id == ^endpoint_id,
        where:
          k.state == :active or
            (k.state == :rotating and k.transitioned_at >= ^grace_cutoff)
      )
    )
  end

  defp check_hmac(body, received_sig, secret) do
    prefix = "sha256="
    bare_sig = String.replace_prefix(received_sig, prefix, "")

    expected =
      :crypto.mac(:hmac, :sha256, secret, body)
      |> Base.encode16(case: :lower)

    Plug.Crypto.secure_compare(expected, bare_sig)
  end
end
```
