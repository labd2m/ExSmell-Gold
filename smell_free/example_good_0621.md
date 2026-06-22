```elixir
defmodule Accounts.EmailVerifier do
  @moduledoc """
  Manages email verification tokens for new user registrations and
  email-change flows. Tokens are single-use, time-limited, and stored
  hashed in the database so a compromised token store cannot be used to
  verify arbitrary accounts. Successful verification records the
  confirmation timestamp and cleans up the token atomically.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Accounts.{EmailToken, User}

  @type user_id :: String.t()
  @type token_context :: :registration | :email_change
  @type issue_result :: {:ok, %{token: String.t(), expires_at: DateTime.t()}}

  @token_bytes 32
  @default_ttl_hours 24

  @doc """
  Issues a new verification token for `user_id` in the given `context`.
  Any existing tokens for the same user and context are replaced.
  """
  @spec issue(user_id(), token_context()) :: issue_result()
  def issue(user_id, context)
      when is_binary(user_id) and context in [:registration, :email_change] do
    Repo.transaction(fn ->
      delete_existing(user_id, context)
      plaintext = generate_token()
      expires_at = DateTime.add(DateTime.utc_now(), @default_ttl_hours * 3_600, :second)

      attrs = %{
        user_id: user_id,
        context: Atom.to_string(context),
        token_hash: hash(plaintext),
        expires_at: expires_at
      }

      Repo.insert!(%EmailToken{} |> EmailToken.changeset(attrs))
      %{token: plaintext, expires_at: expires_at}
    end)
  end

  @doc """
  Verifies `plaintext` token for `context`. On success, marks the user as
  confirmed and deletes the token record atomically. Returns a typed error
  for invalid, expired, or already-consumed tokens.
  """
  @spec verify(String.t(), token_context()) ::
          {:ok, User.t()} | {:error, :invalid | :expired}
  def verify(plaintext, context)
      when is_binary(plaintext) and context in [:registration, :email_change] do
    hash = hash(plaintext)
    ctx_str = Atom.to_string(context)

    case Repo.one(from(t in EmailToken, where: t.token_hash == ^hash and t.context == ^ctx_str)) do
      nil ->
        {:error, :invalid}

      %EmailToken{expires_at: exp} when exp < ^DateTime.utc_now() ->
        {:error, :expired}

      %EmailToken{user_id: user_id} = token ->
        Repo.transaction(fn ->
          Repo.delete!(token)
          confirm_user(user_id, context)
        end)
    end
  end

  @doc "Returns true when `user_id` has an unexpired token for `context`."
  @spec pending?(user_id(), token_context()) :: boolean()
  def pending?(user_id, context) when is_binary(user_id) do
    now = DateTime.utc_now()
    ctx_str = Atom.to_string(context)

    Repo.exists?(
      from(t in EmailToken,
        where: t.user_id == ^user_id and t.context == ^ctx_str and t.expires_at > ^now
      )
    )
  end

  defp delete_existing(user_id, context) do
    ctx_str = Atom.to_string(context)
    Repo.delete_all(from(t in EmailToken, where: t.user_id == ^user_id and t.context == ^ctx_str))
  end

  defp confirm_user(user_id, :registration) do
    case Repo.get(User, user_id) do
      nil -> Repo.rollback(:invalid)
      user -> user |> User.confirmation_changeset() |> Repo.update!()
    end
  end

  defp confirm_user(user_id, :email_change) do
    case Repo.get(User, user_id) do
      nil -> Repo.rollback(:invalid)
      user -> user |> User.activate_pending_email_changeset() |> Repo.update!()
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
  end

  defp hash(plaintext) do
    :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
  end
end
```
