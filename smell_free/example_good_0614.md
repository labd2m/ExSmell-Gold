# File: `example_good_614.md`

```elixir
defmodule Auth.PasswordlessLink do
  @moduledoc """
  Manages the lifecycle of passwordless authentication links (magic links).

  A link is a single-use, time-limited token bound to an email address.
  Issuing a new link for an address revokes any outstanding link for
  that address to prevent token accumulation. Tokens are stored as
  hashes; the plaintext is returned once and never stored.
  """

  import Ecto.Query, warn: false

  alias Auth.{MagicLink, Repo}

  @token_bytes 24
  @default_ttl_minutes 15

  @type email :: String.t()
  @type plaintext_token :: String.t()

  @type issue_result ::
          {:ok, %{token: plaintext_token(), expires_at: DateTime.t()}}
          | {:error, Ecto.Changeset.t()}

  @type verify_result ::
          {:ok, email()}
          | {:error, :invalid}
          | {:error, :expired}
          | {:error, :already_used}

  @doc """
  Issues a new magic link token for `email`.

  Any prior unused token for the same address is revoked before
  creating the new one.

  Returns `{:ok, %{token: plaintext, expires_at: datetime}}`.
  """
  @spec issue(email(), keyword()) :: issue_result()
  def issue(email, opts \\ []) when is_binary(email) do
    ttl_minutes = Keyword.get(opts, :ttl_minutes, @default_ttl_minutes)
    normalized = String.downcase(String.trim(email))

    revoke_existing(normalized)

    plaintext = generate_token()
    token_hash = hash(plaintext)
    expires_at = DateTime.add(DateTime.utc_now(), ttl_minutes * 60, :second)

    attrs = %{email: normalized, token_hash: token_hash, expires_at: expires_at, used: false}

    case attrs |> MagicLink.changeset() |> Repo.insert() do
      {:ok, _record} -> {:ok, %{token: plaintext, expires_at: expires_at}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Verifies a magic link token and returns the associated email.

  The token is consumed on first use; subsequent calls with the same
  token return `{:error, :already_used}`.
  """
  @spec verify(plaintext_token()) :: verify_result()
  def verify(plaintext) when is_binary(plaintext) do
    token_hash = hash(plaintext)

    case Repo.get_by(MagicLink, token_hash: token_hash) do
      nil ->
        {:error, :invalid}

      %MagicLink{used: true} ->
        {:error, :already_used}

      %MagicLink{expires_at: exp} = link when not is_nil(exp) ->
        if DateTime.compare(exp, DateTime.utc_now()) == :lt do
          {:error, :expired}
        else
          consume_link(link)
        end
    end
  end

  @doc """
  Explicitly revokes all outstanding magic links for `email`.
  """
  @spec revoke(email()) :: {non_neg_integer(), nil}
  def revoke(email) when is_binary(email) do
    normalized = String.downcase(String.trim(email))
    revoke_existing(normalized)
  end

  @doc """
  Returns `true` when a valid, unconsumed magic link exists for `email`.
  """
  @spec pending?(email()) :: boolean()
  def pending?(email) when is_binary(email) do
    normalized = String.downcase(String.trim(email))
    now = DateTime.utc_now()

    MagicLink
    |> where([l], l.email == ^normalized and l.used == false and l.expires_at > ^now)
    |> Repo.exists?()
  end

  defp revoke_existing(email) do
    MagicLink
    |> where([l], l.email == ^email and l.used == false)
    |> Repo.update_all(set: [used: true])
  end

  defp consume_link(%MagicLink{email: email} = link) do
    link
    |> MagicLink.consume_changeset(%{used: true, used_at: DateTime.utc_now()})
    |> Repo.update!()

    {:ok, email}
  end

  defp generate_token do
    :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
  end

  defp hash(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end
end
```
