```elixir
defmodule Platform.FileValidator do
  @moduledoc """
  Validates uploaded files by inspecting magic bytes rather than trusting
  the client-supplied content type or file extension.

  Supports configurable allowlists of MIME types and enforces maximum file
  size limits. Returns structured validation results suitable for Ecto
  changeset errors or controller-level rejection.
  """

  @type mime_type :: String.t()
  @type validation_result :: :ok | {:error, :invalid_type | :file_too_large | :empty_file}
  @type opts :: [
          allowed_types: [mime_type()],
          max_bytes: pos_integer()
        ]

  @signatures %{
    "image/jpeg" => [<<0xFF, 0xD8, 0xFF>>],
    "image/png" => [<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>],
    "image/gif" => [<<"GIF87a">>, <<"GIF89a">>],
    "image/webp" => :webp,
    "application/pdf" => [<<"%PDF">>],
    "application/zip" => [<<0x50, 0x4B, 0x03, 0x04>>, <<0x50, 0x4B, 0x05, 0x06>>],
    "text/plain" => :utf8
  }

  @doc """
  Validates `content` against the configured allowlist and size limit.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate(binary(), opts()) :: validation_result()
  def validate(content, opts \\ []) when is_binary(content) do
    max_bytes = Keyword.get(opts, :max_bytes, 10 * 1024 * 1024)
    allowed_types = Keyword.get(opts, :allowed_types, Map.keys(@signatures))

    cond do
      byte_size(content) == 0 -> {:error, :empty_file}
      byte_size(content) > max_bytes -> {:error, :file_too_large}
      true -> check_type(content, allowed_types)
    end
  end

  @doc """
  Detects the MIME type of `content` by inspecting its magic bytes.
  Returns the detected MIME type string or `nil` if unrecognized.
  """
  @spec detect_type(binary()) :: mime_type() | nil
  def detect_type(content) when is_binary(content) do
    Enum.find_value(@signatures, fn {mime, sig} -> if matches?(content, sig), do: mime end)
  end

  @doc """
  Returns `true` if the detected MIME type of `content` is in `allowed_types`.
  """
  @spec allowed_type?(binary(), [mime_type()]) :: boolean()
  def allowed_type?(content, allowed_types) when is_list(allowed_types) do
    case detect_type(content) do
      nil -> false
      detected -> detected in allowed_types
    end
  end

  defp check_type(content, allowed_types) do
    case detect_type(content) do
      nil -> {:error, :invalid_type}
      detected -> if detected in allowed_types, do: :ok, else: {:error, :invalid_type}
    end
  end

  defp matches?(content, :webp) do
    byte_size(content) >= 12 and
      binary_part(content, 0, 4) == "RIFF" and
      binary_part(content, 8, 4) == "WEBP"
  end

  defp matches?(content, :utf8) do
    String.valid?(content)
  end

  defp matches?(content, signatures) when is_list(signatures) do
    Enum.any?(signatures, fn sig ->
      len = byte_size(sig)
      byte_size(content) >= len and binary_part(content, 0, len) == sig
    end)
  end
end
```
