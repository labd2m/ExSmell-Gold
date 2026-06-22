```elixir
defmodule Accounts.TwoFactorBackupCodes do
  @moduledoc """
  Manages one-time backup codes for account recovery when a primary MFA
  device is unavailable. A set of codes is generated once per user;
  each code is stored hashed and marked as used on consumption. Regenerating
  codes invalidates the full previous set atomically.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Accounts.BackupCode

  @type user_id :: String.t()

  @code_count 10
  @code_length 8
  @code_alphabet ~c(23456789ABCDEFGHJKLMNPQRSTUVWXYZ)

  @doc """
  Generates a fresh set of #{@code_count} backup codes for `user_id`.
  Any existing unused codes are invalidated first.
  """
  @spec generate(user_id()) :: {:ok, [String.t()]}
  def generate(user_id) when is_binary(user_id) do
    Repo.transaction(fn ->
      Repo.delete_all(from(c in BackupCode, where: c.user_id == ^user_id))

      codes = for _ <- 1..@code_count, do: random_code()
      now = DateTime.utc_now()

      rows =
        Enum.map(codes, fn code ->
          %{user_id: user_id, code_hash: hash(code), used: false,
            inserted_at: now, updated_at: now}
        end)

      Repo.insert_all(BackupCode, rows)
      codes
    end)
  end

  @doc """
  Attempts to consume `plaintext_code` for `user_id`. Returns
  `{:error, :invalid_code}` when the code is unknown or already used.
  """
  @spec consume(user_id(), String.t()) :: :ok | {:error, :invalid_code}
  def consume(user_id, plaintext_code) when is_binary(user_id) and is_binary(plaintext_code) do
    code_hash = hash(String.upcase(String.trim(plaintext_code)))

    case Repo.get_by(BackupCode, user_id: user_id, code_hash: code_hash, used: false) do
      nil ->
        {:error, :invalid_code}

      backup_code ->
        backup_code
        |> BackupCode.changeset(%{used: true, used_at: DateTime.utc_now()})
        |> Repo.update!()

        :ok
    end
  end

  @doc "Returns the count of remaining unused backup codes for `user_id`."
  @spec remaining_count(user_id()) :: non_neg_integer()
  def remaining_count(user_id) when is_binary(user_id) do
    Repo.one(from(c in BackupCode, where: c.user_id == ^user_id and c.used == false, select: count(c.id))) || 0
  end

  @doc "Returns true when `user_id` has any active (unused) backup codes."
  @spec has_codes?(user_id()) :: boolean()
  def has_codes?(user_id) when is_binary(user_id), do: remaining_count(user_id) > 0

  defp random_code do
    1..@code_length
    |> Enum.map(fn _ -> Enum.random(@code_alphabet) end)
    |> List.to_string()
  end

  defp hash(plaintext) do
    :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
  end
end
```
