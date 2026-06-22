```elixir
defmodule Iam.Tokens.RefreshRotator do
  @moduledoc """
  Issues and rotates refresh tokens for authentication sessions.
  Each rotation invalidates the consumed token and issues a fresh one.
  Token records are stored and validated against a pluggable repository.
  """

  alias Iam.Tokens.{RefreshToken, TokenRepository}

  @token_ttl_days 30

  @type rotate_result ::
          {:ok, %{access_token: String.t(), refresh_token: String.t()}}
          | {:error, :invalid_token | :token_expired | :already_consumed}

  @doc """
  Rotates the given `raw_token` string.

  Validates the token, marks it as consumed, issues a new refresh token,
  and mints a new access token. Returns both tokens on success.
  """
  @spec rotate(String.t(), module()) :: rotate_result()
  def rotate(raw_token, repo \\ TokenRepository) when is_binary(raw_token) do
    with {:ok, token} <- repo.fetch_by_value(raw_token),
         :ok <- assert_not_consumed(token),
         :ok <- assert_not_expired(token),
         :ok <- repo.mark_consumed(token.id),
         {:ok, new_refresh} <- issue_refresh_token(token.subject_id, repo),
         {:ok, access_token} <- mint_access_token(token.subject_id) do
      {:ok, %{access_token: access_token, refresh_token: new_refresh.value}}
    end
  end

  @doc """
  Issues a brand-new refresh token for `subject_id` without rotation.
  Used during initial login.
  """
  @spec issue(String.t(), module()) :: {:ok, RefreshToken.t()} | {:error, String.t()}
  def issue(subject_id, repo \\ TokenRepository) when is_binary(subject_id) do
    issue_refresh_token(subject_id, repo)
  end

  defp issue_refresh_token(subject_id, repo) do
    token = RefreshToken.generate(subject_id, ttl_days: @token_ttl_days)
    repo.insert(token)
  end

  defp assert_not_consumed(%RefreshToken{consumed_at: nil}), do: :ok
  defp assert_not_consumed(%RefreshToken{}), do: {:error, :already_consumed}

  defp assert_not_expired(%RefreshToken{expires_at: exp}) do
    if DateTime.compare(DateTime.utc_now(), exp) == :lt do
      :ok
    else
      {:error, :token_expired}
    end
  end

  defp mint_access_token(subject_id) do
    claims = %{sub: subject_id, iat: System.system_time(:second)}
    Iam.Jwt.sign(claims)
  end
end

defmodule Iam.Tokens.RefreshToken do
  @moduledoc """
  Represents a single refresh token record with expiry and consumption tracking.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          value: String.t(),
          subject_id: String.t(),
          expires_at: DateTime.t(),
          consumed_at: DateTime.t() | nil,
          issued_at: DateTime.t()
        }

  defstruct [:id, :value, :subject_id, :expires_at, :consumed_at, :issued_at]

  @doc """
  Generates a new unsigned refresh token for `subject_id`.
  """
  @spec generate(String.t(), keyword()) :: t()
  def generate(subject_id, opts \\ []) when is_binary(subject_id) do
    ttl_days = Keyword.get(opts, :ttl_days, 30)
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, ttl_days * 86_400, :second)

    %__MODULE__{
      id: Ecto.UUID.generate(),
      value: secure_random(),
      subject_id: subject_id,
      expires_at: expires_at,
      consumed_at: nil,
      issued_at: now
    }
  end

  defp secure_random do
    :crypto.strong_rand_bytes(48) |> Base.url_encode64(padding: false)
  end
end
```
