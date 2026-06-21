# File: `example_good_201.md`

```elixir
defmodule Cryptography.SecretVault do
  @moduledoc """
  Provides authenticated encryption and decryption of sensitive values
  using AES-256-GCM with a randomly generated nonce per operation.

  The encryption key is never embedded in the stored ciphertext; it is
  always provided explicitly by the caller, enabling key rotation by
  re-encrypting stored values with the new key.
  """

  @cipher :aes_256_gcm
  @tag_length 16
  @nonce_length 12
  @key_length 32

  @type key :: <<_::256>>
  @type plaintext :: String.t() | binary()
  @type ciphertext_blob :: binary()
  @type aad :: binary()

  @doc """
  Encrypts `plaintext` with `key` using AES-256-GCM.

  An optional `aad` (additional authenticated data) binds the ciphertext
  to a specific context (e.g. a record ID) without encrypting it.

  Returns a binary blob containing the nonce, authentication tag, and
  ciphertext concatenated. This blob is safe to store in the database.
  """
  @spec encrypt(plaintext(), key(), aad()) ::
          {:ok, ciphertext_blob()} | {:error, :invalid_key}
  def encrypt(plaintext, key, aad \\ "")
      when is_binary(plaintext) and is_binary(key) and is_binary(aad) do
    with :ok <- validate_key(key) do
      nonce = :crypto.strong_rand_bytes(@nonce_length)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(@cipher, key, nonce, plaintext, aad, @tag_length, true)

      blob = nonce <> tag <> ciphertext
      {:ok, blob}
    end
  end

  @doc """
  Decrypts a blob produced by `encrypt/3`.

  The same `key` and `aad` used for encryption must be provided.
  Returns `{:ok, plaintext}` or `{:error, reason}`.
  """
  @spec decrypt(ciphertext_blob(), key(), aad()) ::
          {:ok, plaintext()} | {:error, :invalid_key | :decryption_failed}
  def decrypt(blob, key, aad \\ "")
      when is_binary(blob) and is_binary(key) and is_binary(aad) do
    min_size = @nonce_length + @tag_length

    with :ok <- validate_key(key),
         {:ok, {nonce, tag, ciphertext}} <- split_blob(blob, min_size) do
      case :crypto.crypto_one_time_aead(@cipher, key, nonce, ciphertext, aad, tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :decryption_failed}
      end
    end
  end

  @doc """
  Re-encrypts `blob` from `old_key` to `new_key` with the same `aad`.

  Performs a decrypt then encrypt in a single call to simplify key
  rotation workflows. Returns `{:ok, new_blob}` or an error.
  """
  @spec reencrypt(ciphertext_blob(), key(), key(), aad()) ::
          {:ok, ciphertext_blob()} | {:error, atom()}
  def reencrypt(blob, old_key, new_key, aad \\ "") do
    with {:ok, plaintext} <- decrypt(blob, old_key, aad),
         {:ok, new_blob} <- encrypt(plaintext, new_key, aad) do
      {:ok, new_blob}
    end
  end

  @doc """
  Derives a 256-bit encryption key from a password and salt using PBKDF2-SHA256.

  Use a unique random salt per key derivation and persist it alongside
  the ciphertext to allow future decryption.
  """
  @spec derive_key(String.t(), binary(), pos_integer()) :: key()
  def derive_key(password, salt, iterations \\ 100_000)
      when is_binary(password) and is_binary(salt) and is_integer(iterations) and iterations > 0 do
    :crypto.pbkdf2(:sha256, password, salt, iterations, @key_length)
  end

  @doc """
  Generates a cryptographically random 256-bit encryption key.
  """
  @spec generate_key() :: key()
  def generate_key do
    :crypto.strong_rand_bytes(@key_length)
  end

  @doc """
  Generates a random salt suitable for use with `derive_key/3`.
  """
  @spec generate_salt() :: binary()
  def generate_salt do
    :crypto.strong_rand_bytes(16)
  end

  defp validate_key(key) when byte_size(key) == @key_length, do: :ok
  defp validate_key(_key), do: {:error, :invalid_key}

  defp split_blob(blob, min_size) when byte_size(blob) > min_size do
    <<nonce::binary-size(@nonce_length), tag::binary-size(@tag_length), ciphertext::binary>> = blob
    {:ok, {nonce, tag, ciphertext}}
  end

  defp split_blob(_blob, _min_size), do: {:error, :decryption_failed}
end
```
