# Code Smell Example – Annotated

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `FileUploader.store/2`
- **Affected function(s):** `store/2`, `validate/1`
- **Short explanation:** The library fetches `:max_file_size_bytes`, `:allowed_mime_types`, and `:storage_path` from the global `Application Environment` instead of accepting them as parameters. A dependent application that accepts both profile photos (small JPEG/PNG) and PDF invoices (larger, different type) cannot apply different validation rules to each upload type without a global config change.

```elixir
defmodule FileUploader do
  @moduledoc """
  A file upload handling library that validates, stores, and manages
  user-uploaded files. Designed for use in web applications processing
  form-based and API-based file uploads.

  Configuration (config/config.exs):

      config :file_uploader,
        max_file_size_bytes: 5_242_880,
        allowed_mime_types: ["image/jpeg", "image/png", "image/webp"],
        storage_path: "/var/app/uploads"
  """

  require Logger

  @doc """
  Validates and stores an uploaded file. Returns `{:ok, file_path}` on
  success or `{:error, reason}` on validation failure.
  """
  @spec store(%{filename: String.t(), content_type: String.t(), path: String.t()}) ::
          {:ok, String.t()} | {:error, String.t()}
  def store(upload, _opts \\ []) do
    with :ok <- validate(upload) do
      dest = build_destination(upload.filename)

      case File.cp(upload.path, dest) do
        :ok ->
          Logger.info("[FileUploader] Stored #{upload.filename} -> #{dest}")
          {:ok, dest}

        {:error, reason} ->
          {:error, "Failed to write file: #{:file.format_error(reason)}"}
      end
    end
  end

  @doc """
  Validates an upload map against the configured size and MIME type rules.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate(%{filename: String.t(), content_type: String.t(), path: String.t()}) ::
          :ok | {:error, String.t()}
  def validate(%{filename: filename, content_type: content_type, path: path}) do
    # VALIDATION: SMELL START - Using App Configuration for libraries
    # VALIDATION: This is a smell because the library fetches :max_file_size_bytes
    # and :allowed_mime_types from the global Application Environment instead of
    # accepting them as function parameters. An application that needs to allow
    # only small images for avatars but large PDFs for invoices cannot call
    # validate/1 with different rules per context. Every call site shares the
    # same global constraints, eliminating the library's reusability for
    # multi-context upload scenarios.
    max_bytes = Application.fetch_env!(:file_uploader, :max_file_size_bytes)
    allowed_types = Application.fetch_env!(:file_uploader, :allowed_mime_types)
    # VALIDATION: SMELL END

    with :ok <- validate_filename(filename),
         :ok <- validate_mime_type(content_type, allowed_types),
         :ok <- validate_file_size(path, max_bytes) do
      :ok
    end
  end

  @doc """
  Deletes a previously stored file by its path.
  """
  @spec delete(String.t()) :: :ok | {:error, String.t()}
  def delete(file_path) when is_binary(file_path) do
    storage_path = Application.fetch_env!(:file_uploader, :storage_path)

    unless String.starts_with?(file_path, storage_path) do
      {:error, "Refusing to delete file outside of configured storage path"}
    else
      case File.rm(file_path) do
        :ok ->
          Logger.info("[FileUploader] Deleted #{file_path}")
          :ok

        {:error, reason} ->
          {:error, "Could not delete file: #{:file.format_error(reason)}"}
      end
    end
  end

  @doc """
  Lists all files currently stored under the configured storage path.
  """
  @spec list_stored() :: {:ok, list(String.t())} | {:error, String.t()}
  def list_stored do
    storage_path = Application.fetch_env!(:file_uploader, :storage_path)

    case File.ls(storage_path) do
      {:ok, files} ->
        full_paths = Enum.map(files, &Path.join(storage_path, &1))
        {:ok, full_paths}

      {:error, reason} ->
        {:error, "Could not list storage directory: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Returns the size in bytes of a file at the given path.
  """
  @spec file_size(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def file_size(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, "Could not stat file: #{:file.format_error(reason)}"}
    end
  end

  # --- Private helpers ---

  defp build_destination(filename) do
    storage_path = Application.fetch_env!(:file_uploader, :storage_path)
    safe_name = sanitize_filename(filename)
    unique = :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
    Path.join(storage_path, "#{unique}_#{safe_name}")
  end

  defp sanitize_filename(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^\w.\-]/, "_")
  end

  defp validate_filename(filename) do
    if String.length(filename) > 255 or String.contains?(filename, ["../", "//"]) do
      {:error, "Filename is invalid or contains path traversal sequences"}
    else
      :ok
    end
  end

  defp validate_mime_type(content_type, allowed) do
    if content_type in allowed do
      :ok
    else
      {:error, "MIME type '#{content_type}' is not permitted. Allowed: #{Enum.join(allowed, ", ")}"}
    end
  end

  defp validate_file_size(path, max_bytes) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size <= max_bytes ->
        :ok

      {:ok, %File.Stat{size: size}} ->
        {:error, "File size #{size} bytes exceeds the maximum of #{max_bytes} bytes"}

      {:error, reason} ->
        {:error, "Cannot stat file: #{:file.format_error(reason)}"}
    end
  end
end
```
