```elixir
defmodule Platform.EncryptedField do
  @moduledoc """
  A custom `Ecto.Type` that transparently encrypts values before writing to
  the database and decrypts them on read.

  Encryption uses AES-256-GCM with a random 12-byte IV prepended to the
  ciphertext. The result is base64-encoded for storage in a text column.
  The encryption key is fetched at runtime from application config.
  """

  use Ecto.Type

  @aad "encrypted_field_v1"
  @iv_bytes 12

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}

  def load(ciphertext) when is_binary(ciphertext) do
    case decrypt(ciphertext) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, _} -> :error
    end
  end

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}

  def dump(plaintext) when is_binary(plaintext) do
    case encrypt(plaintext) do
      {:ok, ciphertext} -> {:ok, ciphertext}
      {:error, _} -> :error
    end
  end

  def dump(_), do: :error

  @impl Ecto.Type
  def equal?(a, b), do: a == b

  @impl Ecto.Type
  def embed_as(_), do: :self

  @doc "Encrypts `plaintext` using AES-256-GCM, returning a base64-encoded ciphertext."
  @spec encrypt(String.t()) :: {:ok, String.t()} | {:error, term()}
  def encrypt(plaintext) when is_binary(plaintext) do
    key = fetch_key()
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)

    encoded = Base.encode64(iv <> tag <> ciphertext)
    {:ok, encoded}
  rescue
    error -> {:error, error}
  end

  @doc "Decrypts a previously encrypted base64 ciphertext string."
  @spec decrypt(String.t()) :: {:ok, String.t()} | {:error, :decryption_failed}
  def decrypt(encoded) when is_binary(encoded) do
    key = fetch_key()

    with {:ok, binary} <- Base.decode64(encoded),
         <<iv::binary-size(@iv_bytes), tag::binary-size(16), ciphertext::binary>> <- binary,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      {:ok, plaintext}
    else
      _ -> {:error, :decryption_failed}
    end
  rescue
    _ -> {:error, :decryption_failed}
  end

  defp fetch_key do
    raw = Application.fetch_env!(:platform, :field_encryption_key)

    case Base.decode64(raw) do
      {:ok, key} when byte_size(key) == 32 -> key
      _ -> raise ArgumentError, "field_encryption_key must be a base64-encoded 32-byte key"
    end
  end
end
```
