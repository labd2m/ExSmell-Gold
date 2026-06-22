**File:** `example_good_1065.md`

```elixir
defmodule Accounts.Registration do
  @moduledoc """
  Orchestrates new user registration, including account creation,
  email verification token generation, and welcome notification dispatch.
  All steps are wrapped in a database transaction; failures roll back cleanly.
  """

  alias Accounts.{Repo, User, EmailVerification, Notifications}
  alias Ecto.Multi

  @type registration_params :: %{
          email: String.t(),
          password: String.t(),
          full_name: String.t(),
          timezone: String.t() | nil
        }

  @spec register(registration_params()) ::
          {:ok, %{user: User.t(), verification: EmailVerification.t()}}
          | {:error, Multi.name(), term(), map()}
  def register(%{email: _, password: _, full_name: _} = params) do
    Multi.new()
    |> Multi.insert(:user, build_user_changeset(params))
    |> Multi.insert(:verification, &build_verification_changeset/1)
    |> Multi.run(:notification, &send_welcome_email/2)
    |> Repo.transaction()
  end

  @spec confirm_email(String.t()) ::
          {:ok, User.t()} | {:error, :invalid_token | :expired_token | :already_confirmed}
  def confirm_email(token) when is_binary(token) do
    with {:ok, verification} <- fetch_valid_verification(token),
         {:ok, user} <- mark_email_confirmed(verification) do
      {:ok, user}
    end
  end

  @spec resend_verification(User.t()) ::
          {:ok, EmailVerification.t()} | {:error, :already_confirmed}
  def resend_verification(%User{email_confirmed: true}), do: {:error, :already_confirmed}

  def resend_verification(%User{} = user) do
    Multi.new()
    |> Multi.delete_all(:old_tokens, build_old_tokens_query(user))
    |> Multi.insert(:verification, build_verification_for_user(user))
    |> Multi.run(:notification, fn _repo, %{verification: v} ->
      Notifications.send_verification_email(user, v.token)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{verification: v}} -> {:ok, v}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp build_user_changeset(params) do
    %User{}
    |> User.registration_changeset(params)
  end

  defp build_verification_changeset(%{user: user}) do
    EmailVerification.create_changeset(%EmailVerification{}, %{
      user_id: user.id,
      token: generate_token(),
      expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
    })
  end

  defp build_verification_for_user(user) do
    EmailVerification.create_changeset(%EmailVerification{}, %{
      user_id: user.id,
      token: generate_token(),
      expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
    })
  end

  defp send_welcome_email(_repo, %{user: user, verification: verification}) do
    Notifications.send_welcome_email(user, verification.token)
  end

  defp fetch_valid_verification(token) do
    import Ecto.Query

    now = DateTime.utc_now()

    case Repo.one(
           from v in EmailVerification,
             where: v.token == ^token and v.used_at is nil,
             preload: [:user]
         ) do
      nil -> {:error, :invalid_token}
      %{expires_at: exp} when exp < now -> {:error, :expired_token}
      verification -> {:ok, verification}
    end
  end

  defp mark_email_confirmed(verification) do
    Repo.transaction(fn ->
      {:ok, _} =
        verification
        |> EmailVerification.use_changeset()
        |> Repo.update()

      {:ok, user} =
        verification.user
        |> User.confirm_email_changeset()
        |> Repo.update()

      user
    end)
  end

  defp build_old_tokens_query(user) do
    import Ecto.Query
    from v in EmailVerification, where: v.user_id == ^user.id and is_nil(v.used_at)
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
```
