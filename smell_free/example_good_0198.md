# File: `example_good_198.md`

```elixir
defmodule Accounts.InvitationFlow do
  @moduledoc """
  Manages the lifecycle of user invitations: creation, acceptance,
  expiry, and revocation.

  Invitation tokens are single-use and time-limited. Once accepted,
  the token is consumed atomically with the new user account creation
  to prevent replay attacks.
  """

  import Ecto.Query, warn: false

  alias Accounts.{Invitation, Repo, User}

  @token_byte_length 24
  @default_ttl_hours 72

  @type inviter :: User.t()
  @type email :: String.t()
  @type token :: String.t()
  @type invitation_result :: {:ok, Invitation.t()} | {:error, Ecto.Changeset.t() | atom()}

  @doc """
  Creates a new invitation for `email`, issued by `inviter`.

  An existing pending invitation for the same email is revoked first
  so there is at most one active invitation per address at any time.

  Returns `{:ok, invitation}` with the record that contains the plaintext token.
  """
  @spec invite(inviter(), email(), keyword()) :: invitation_result()
  def invite(%User{} = inviter, email, opts \\ []) when is_binary(email) do
    ttl_hours = Keyword.get(opts, :ttl_hours, @default_ttl_hours)
    normalized = String.downcase(String.trim(email))

    with :ok <- revoke_existing(normalized),
         {:ok, invitation} <- create_invitation(inviter, normalized, ttl_hours) do
      {:ok, invitation}
    end
  end

  @doc """
  Accepts an invitation by token and creates the associated user account.

  Returns `{:ok, %{invitation: inv, user: user}}` on success, or one of:
  - `{:error, :not_found}` — token does not exist
  - `{:error, :already_used}` — invitation was already accepted
  - `{:error, :expired}` — invitation has passed its expiry date
  - `{:error, changeset}` — user creation validation failed
  """
  @spec accept(token(), map()) ::
          {:ok, %{invitation: Invitation.t(), user: User.t()}}
          | {:error, Ecto.Changeset.t() | atom()}
  def accept(token, user_attrs) when is_binary(token) and is_map(user_attrs) do
    hashed = hash_token(token)

    case Repo.get_by(Invitation, token_hash: hashed) do
      nil -> {:error, :not_found}
      invitation -> process_acceptance(invitation, user_attrs)
    end
  end

  @doc """
  Revokes all pending invitations for the given email address.
  """
  @spec revoke_for(email()) :: {non_neg_integer(), nil}
  def revoke_for(email) when is_binary(email) do
    normalized = String.downcase(String.trim(email))

    Invitation
    |> where([i], i.email == ^normalized and i.status == :pending)
    |> Repo.update_all(set: [status: :revoked, revoked_at: DateTime.utc_now()])
  end

  @doc """
  Returns all pending invitations that have passed their expiry timestamp.
  """
  @spec list_expired() :: [Invitation.t()]
  def list_expired do
    now = DateTime.utc_now()

    Invitation
    |> where([i], i.status == :pending and i.expires_at < ^now)
    |> Repo.all()
  end

  defp revoke_existing(email) do
    revoke_for(email)
    :ok
  end

  defp create_invitation(inviter, email, ttl_hours) do
    plaintext = generate_token()
    expires_at = DateTime.add(DateTime.utc_now(), ttl_hours * 3600, :second)

    attrs = %{
      inviter_id: inviter.id,
      email: email,
      token_hash: hash_token(plaintext),
      expires_at: expires_at,
      status: :pending
    }

    case attrs |> Invitation.changeset() |> Repo.insert() do
      {:ok, record} -> {:ok, %{record | plaintext_token: plaintext}}
      {:error, _} = error -> error
    end
  end

  defp process_acceptance(%Invitation{status: :accepted}, _attrs), do: {:error, :already_used}
  defp process_acceptance(%Invitation{status: :revoked}, _attrs), do: {:error, :not_found}

  defp process_acceptance(%Invitation{expires_at: exp} = invitation, user_attrs) do
    if DateTime.compare(exp, DateTime.utc_now()) == :lt do
      {:error, :expired}
    else
      accept_transactionally(invitation, user_attrs)
    end
  end

  defp accept_transactionally(invitation, user_attrs) do
    Repo.transaction(fn ->
      {:ok, user} =
        user_attrs
        |> Map.put(:email, invitation.email)
        |> User.registration_changeset()
        |> Repo.insert!()
        |> then(&{:ok, &1})

      {:ok, updated_invitation} =
        invitation
        |> Invitation.accept_changeset(%{status: :accepted, accepted_at: DateTime.utc_now()})
        |> Repo.update!()
        |> then(&{:ok, &1})

      %{invitation: updated_invitation, user: user}
    end)
  end

  defp generate_token do
    :crypto.strong_rand_bytes(@token_byte_length) |> Base.url_encode64(padding: false)
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end
end
```
