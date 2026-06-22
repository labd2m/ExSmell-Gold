```elixir
defmodule Platform.EncryptedFieldStore do
  @moduledoc """
  Provides transparent field-level encryption for sensitive database values.
  Plaintext is encrypted with AES-256-GCM before persistence and decrypted
  on read. A random IV is generated per value and stored alongside the
  ciphertext so values cannot be correlated by ciphertext equality.
  The encryption key is fetched from the secret manager at call time.
  """

  @aes_key_bits 256
  @aes_key_bytes div(@aes_key_bits, 8)
  @iv_bytes 12
  @tag_bytes 16
  @version 1

  @type plaintext :: String.t() | binary()
  @type encrypted_blob :: binary()

  @doc """
  Encrypts `plaintext` using AES-256-GCM. Returns a versioned binary blob
  that can be stored in any binary database column.
  """
  @spec encrypt(plaintext()) :: {:ok, encrypted_blob()} | {:error, :key_unavailable}
  def encrypt(plaintext) when is_binary(plaintext) do
    with {:ok, key} <- fetch_key() do
      iv = :crypto.strong_rand_bytes(@iv_bytes)
      {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "", true)
      blob = <<@version::8, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>
      {:ok, Base.encode64(blob)}
    end
  end

  @doc """
  Decrypts an encrypted blob produced by `encrypt/1`. Returns
  `{:error, :decryption_failed}` for tampered or key-mismatched values.
  """
  @spec decrypt(encrypted_blob()) :: {:ok, plaintext()} | {:error, :decryption_failed | :key_unavailable}
  def decrypt(blob) when is_binary(blob) do
    with {:ok, key} <- fetch_key(),
         {:ok, raw} <- safe_decode64(blob),
         {:ok, plaintext} <- do_decrypt(raw, key) do
      {:ok, plaintext}
    end
  end

  @doc "Returns true when `blob` is a well-formed encrypted value for the current key."
  @spec valid?(encrypted_blob()) :: boolean()
  def valid?(blob) when is_binary(blob) do
    match?({:ok, _}, decrypt(blob))
  end

  @doc "Re-encrypts a blob with the current key. Used during key rotation."
  @spec rotate(encrypted_blob()) :: {:ok, encrypted_blob()} | {:error, term()}
  def rotate(blob) when is_binary(blob) do
    with {:ok, plaintext} <- decrypt(blob) do
      encrypt(plaintext)
    end
  end

  defp do_decrypt(<<@version::8, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>, key) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :decryption_failed}
    end
  rescue
    _ -> {:error, :decryption_failed}
  end

  defp do_decrypt(_, _), do: {:error, :decryption_failed}

  defp safe_decode64(blob) do
    case Base.decode64(blob) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, :decryption_failed}
    end
  end

  defp fetch_key do
    case Infra.SecretManager.fetch("field_encryption_key") do
      {:ok, key_b64} ->
        case Base.decode64(key_b64) do
          {:ok, key} when byte_size(key) == @aes_key_bytes -> {:ok, key}
          _ -> {:error, :key_unavailable}
        end

      {:error, _} ->
        {:error, :key_unavailable}
    end
  end
end
```
