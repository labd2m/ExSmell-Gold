```elixir
defmodule Security.FieldEncryptor do
  @moduledoc """
  Provides AES-256-GCM authenticated encryption and decryption for
  sensitive model fields (SSNs, credit card PANs, health record numbers).
  Each ciphertext is self-contained: it embeds the IV and authentication tag.
  """

  require Logger

  @encryption_key Application.fetch_env!(:security, :encryption_key)

  @cipher :aes_256_gcm
  @iv_bytes 12
  @tag_bytes 16
  @key_bytes 32
  @aad "field_encryption_v1"

  @type encrypt_result :: {:ok, String.t()} | {:error, :encryption_failed}
  @type decrypt_result :: {:ok, String.t()} | {:error, :decryption_failed | :tampered}

  @spec encrypt(String.t()) :: encrypt_result()
  def encrypt(plaintext) when is_binary(plaintext) do
    key = derived_key()
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    case :crypto.crypto_one_time_aead(@cipher, key, iv, plaintext, @aad, true) do
      {ciphertext, tag} ->
        encoded = Base.encode64(iv <> tag <> ciphertext)
        {:ok, encoded}

      _ ->
        Logger.error("Encryption failed")
        {:error, :encryption_failed}
    end
  rescue
    e ->
      Logger.error("Unexpected encryption error", reason: inspect(e))
      {:error, :encryption_failed}
  end

  @spec decrypt(String.t()) :: decrypt_result()
  def decrypt(encoded) when is_binary(encoded) do
    with {:ok, blob} <- Base.decode64(encoded),
         {:ok, {iv, tag, ciphertext}} <- split_blob(blob) do
      key = derived_key()

      case :crypto.crypto_one_time_aead(@cipher, key, iv, ciphertext, @aad, tag, false) do
        plaintext when is_binary(plaintext) ->
          {:ok, plaintext}

        :error ->
          Logger.warning("Decryption authentication failed — possible tampering")
          {:error, :tampered}
      end
    else
      _ ->
        {:error, :decryption_failed}
    end
  rescue
    e ->
      Logger.error("Unexpected decryption error", reason: inspect(e))
      {:error, :decryption_failed}
  end

  @spec rotate(String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def rotate(encoded, new_encoded_key) when is_binary(encoded) and is_binary(new_encoded_key) do
    with {:ok, plaintext} <- decrypt(encoded) do
      new_key = Base.decode64!(new_encoded_key)
      encrypt_with_key(plaintext, new_key)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp derived_key do
    key_material = if is_binary(@encryption_key) and byte_size(@encryption_key) == @key_bytes do
      @encryption_key
    else
      :crypto.hash(:sha256, @encryption_key)
    end

    key_material
  end

  defp split_blob(blob) do
    case blob do
      <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>> ->
        {:ok, {iv, tag, ciphertext}}

      _ ->
        {:error, :malformed_blob}
    end
  end

  defp encrypt_with_key(plaintext, key) when byte_size(key) == @key_bytes do
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    case :crypto.crypto_one_time_aead(@cipher, key, iv, plaintext, @aad, true) do
      {ciphertext, tag} -> {:ok, Base.encode64(iv <> tag <> ciphertext)}
      _ -> {:error, :encryption_failed}
    end
  end

  defp encrypt_with_key(_, _), do: {:error, :invalid_key_length}
end
```
