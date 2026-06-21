```elixir
defmodule Assets.UploadPolicy do
  @moduledoc """
  Validates file uploads before storage. Policies cover MIME type allowlists,
  file size ceilings, and filename sanitation. Each check is a focused
  private function so new constraints can be added without touching
  existing logic. Returns a structured error list rather than raising so
  callers can present user-friendly messages.
  """

  @type upload :: %{
          filename: String.t(),
          content_type: String.t(),
          size_bytes: non_neg_integer(),
          data: binary()
        }

  @type policy_violation :: %{check: atom(), message: String.t()}
  @type policy_result :: :ok | {:error, [policy_violation()]}

  @max_size_bytes 20 * 1024 * 1024
  @allowed_mime_types ~w(
    image/jpeg image/png image/webp image/gif
    application/pdf
    text/csv text/plain
    application/zip
  )
  @blocked_extensions ~w(.exe .bat .sh .ps1 .cmd .vbs .js .php)

  @doc "Validates `upload` against all policies. Returns all violations."
  @spec validate(upload()) :: policy_result()
  def validate(%{filename: _, content_type: _, size_bytes: _, data: _} = upload) do
    violations =
      [
        &check_size/1,
        &check_mime_type/1,
        &check_extension/1,
        &check_filename_safety/1
      ]
      |> Enum.flat_map(fn check ->
        case check.(upload) do
          :ok -> []
          {:error, check_name, msg} -> [%{check: check_name, message: msg}]
        end
      end)

    if Enum.empty?(violations), do: :ok, else: {:error, violations}
  end

  @doc "Sanitises a filename by stripping path components and unsafe characters."
  @spec sanitise_filename(String.t()) :: String.t()
  def sanitise_filename(filename) when is_binary(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^a-zA-Z0-9._\-]/, "_")
    |> String.trim_leading(".")
  end

  defp check_size(%{size_bytes: size}) when size > @max_size_bytes do
    max_mb = div(@max_size_bytes, 1024 * 1024)
    {:error, :file_too_large, "file size exceeds the #{max_mb} MB limit"}
  end

  defp check_size(_), do: :ok

  defp check_mime_type(%{content_type: ct}) do
    if ct in @allowed_mime_types, do: :ok,
      else: {:error, :disallowed_mime_type, "MIME type '#{ct}' is not permitted"}
  end

  defp check_extension(%{filename: name}) do
    ext = name |> Path.extname() |> String.downcase()
    if ext in @blocked_extensions do
      {:error, :blocked_extension, "file extension '#{ext}' is not permitted"}
    else
      :ok
    end
  end

  defp check_filename_safety(%{filename: name}) do
    cond do
      String.contains?(name, "..") ->
        {:error, :unsafe_filename, "filename must not contain path traversal sequences"}
      String.length(name) > 255 ->
        {:error, :filename_too_long, "filename must not exceed 255 characters"}
      true ->
        :ok
    end
  end
end
```
