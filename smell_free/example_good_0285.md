```elixir
defmodule MyApp.Accounts.InvitationFlow do
  @moduledoc """
  Manages the full lifecycle of team member invitations: creating a signed
  invitation token, accepting it to provision a new account, and revoking
  outstanding invitations when a seat is removed. Token signing uses HMAC
  so invitations cannot be forged without the application secret.

  All state changes use `Ecto.Multi` to guarantee atomicity between the
  invitation record and the account provisioned on acceptance.
  """

  alias Ecto.Multi
  alias MyApp.Repo
  alias MyApp.Accounts.{Invitation, User}
  alias MyApp.Mailer

  @token_hmac_key Application.compile_env!(:my_app, :invitation_hmac_key)
  @token_validity_hours 72

  @type invite_params :: %{
          required(:email) => String.t(),
          required(:role) => atom(),
          required(:team_id) => String.t(),
          required(:invited_by_id) => String.t()
        }

  @doc """
  Creates an invitation record, signs a delivery token, and emails the
  invitee. Returns `{:ok, invitation}` or `{:error, changeset}`.
  """
  @spec invite(invite_params()) :: {:ok, Invitation.t()} | {:error, Ecto.Changeset.t()}
  def invite(params) when is_map(params) do
    with {:ok, invitation} <- create_invitation(params) do
      token = sign_token(invitation.id)
      deliver_email(invitation, token)
      {:ok, invitation}
    end
  end

  @doc """
  Accepts an invitation using a signed `token`, creating the user account
  and marking the invitation as accepted atomically.
  Returns `{:error, :invalid_token}` for expired or tampered tokens.
  """
  @spec accept(String.t(), map()) ::
          {:ok, User.t()} | {:error, :invalid_token} | {:error, atom(), term(), map()}
  def accept(token, user_params) when is_binary(token) and is_map(user_params) do
    with {:ok, invitation_id} <- verify_token(token),
         {:ok, invitation} <- fetch_pending(invitation_id) do
      Multi.new()
      |> Multi.run(:user, fn _repo, _changes ->
        create_user(invitation, user_params)
      end)
      |> Multi.run(:invitation, fn _repo, _changes ->
        accept_invitation(invitation)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user}} -> {:ok, user}
        {:error, step, reason, changes} -> {:error, step, reason, changes}
      end
    end
  end

  @doc "Revokes all pending invitations for `email` within `team_id`."
  @spec revoke(String.t(), String.t()) :: non_neg_integer()
  def revoke(email, team_id) when is_binary(email) and is_binary(team_id) do
    import Ecto.Query, warn: false

    {count, _} =
      Invitation
      |> where([i], i.email == ^email and i.team_id == ^team_id and i.status == :pending)
      |> Repo.update_all(set: [status: :revoked, updated_at: DateTime.utc_now()])

    count
  end

  @spec create_invitation(invite_params()) ::
          {:ok, Invitation.t()} | {:error, Ecto.Changeset.t()}
  defp create_invitation(params) do
    expires_at = DateTime.add(DateTime.utc_now(), @token_validity_hours, :hour)

    %Invitation{}
    |> Invitation.changeset(Map.put(params, :expires_at, expires_at))
    |> Repo.insert()
  end

  @spec sign_token(String.t()) :: String.t()
  defp sign_token(invitation_id) do
    payload = "#{invitation_id}.#{System.os_time(:second)}"
    sig = :crypto.mac(:hmac, :sha256, @token_hmac_key, payload) |> Base.url_encode64(padding: false)
    "#{Base.url_encode64(payload, padding: false)}.#{sig}"
  end

  @spec verify_token(String.t()) :: {:ok, String.t()} | {:error, :invalid_token}
  defp verify_token(token) do
    with [encoded_payload, sig] <- String.split(token, ".", parts: 2),
         {:ok, payload} <- Base.url_decode64(encoded_payload, padding: false),
         [invitation_id, ts_str] <- String.split(payload, "."),
         {ts, ""} <- Integer.parse(ts_str),
         true <- System.os_time(:second) - ts <= @token_validity_hours * 3_600,
         expected_sig = :crypto.mac(:hmac, :sha256, @token_hmac_key, payload)
                          |> Base.url_encode64(padding: false),
         true <- Plug.Crypto.secure_compare(sig, expected_sig) do
      {:ok, invitation_id}
    else
      _ -> {:error, :invalid_token}
    end
  end

  @spec fetch_pending(String.t()) :: {:ok, Invitation.t()} | {:error, :invalid_token}
  defp fetch_pending(id) do
    case Repo.get_by(Invitation, id: id, status: :pending) do
      nil -> {:error, :invalid_token}
      inv -> {:ok, inv}
    end
  end

  @spec create_user(Invitation.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  defp create_user(invitation, params) do
    %User{}
    |> User.registration_changeset(Map.merge(params, %{email: invitation.email, role: invitation.role, team_id: invitation.team_id}))
    |> Repo.insert()
  end

  @spec accept_invitation(Invitation.t()) :: {:ok, Invitation.t()} | {:error, Ecto.Changeset.t()}
  defp accept_invitation(invitation) do
    invitation
    |> Invitation.accept_changeset()
    |> Repo.update()
  end

  @spec deliver_email(Invitation.t(), String.t()) :: :ok
  defp deliver_email(invitation, token) do
    case Mailer.deliver_invitation(invitation.email, token) do
      {:ok, _} -> :ok
      {:error, reason} ->
        require Logger
        Logger.warning("invitation_email_failed", email: invitation.email, reason: inspect(reason))
    end
  end
end
```
