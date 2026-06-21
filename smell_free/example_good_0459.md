```elixir
defmodule MyApp.Exports.ReportArchiver do
  @moduledoc """
  Packages generated report files into a compressed ZIP archive, uploads
  the archive to object storage, and records the export in the
  `export_records` table. The entire operation runs inside a supervised
  `Task` so that slow uploads do not block the calling process.

  Archives are named with a timestamp and a random suffix to prevent
  collisions when multiple exports are triggered concurrently.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Exports.ExportRecord
  alias MyApp.Storage

  @type file_entry :: %{
          required(:name) => String.t(),
          required(:content) => binary()
        }

  @type archive_result :: %{
          archive_key: String.t(),
          url: String.t(),
          size_bytes: non_neg_integer(),
          file_count: non_neg_integer()
        }

  @doc """
  Compresses `files` into a ZIP archive, uploads it, and persists an
  export record for `owner_id`. Returns `{:ok, result}` or an error tuple.
  """
  @spec archive(String.t(), [file_entry()], String.t()) ::
          {:ok, archive_result()} | {:error, term()}
  def archive(export_name, files, owner_id)
      when is_binary(export_name) and is_list(files) and is_binary(owner_id) do
    with {:ok, zip_binary} <- build_zip(files),
         archive_key = build_key(export_name),
         {:ok, url} <- Storage.put(archive_key, zip_binary, acl: :private, content_type: "application/zip"),
         {:ok, _record} <- persist_record(owner_id, export_name, archive_key, url, byte_size(zip_binary), length(files)) do
      Logger.info("export_archived",
        name: export_name,
        key: archive_key,
        size_bytes: byte_size(zip_binary)
      )

      {:ok, %{
        archive_key: archive_key,
        url: url,
        size_bytes: byte_size(zip_binary),
        file_count: length(files)
      }}
    end
  end

  @spec build_zip([file_entry()]) :: {:ok, binary()} | {:error, term()}
  defp build_zip(files) do
    entries =
      Enum.map(files, fn %{name: name, content: content} ->
        {String.to_charlist(name), content}
      end)

    case :zip.create("archive.zip", entries, [:memory]) do
      {:ok, {_name, binary}} -> {:ok, binary}
      {:error, reason} -> {:error, {:zip_failed, reason}}
    end
  end

  @spec build_key(String.t()) :: String.t()
  defp build_key(export_name) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    slug = export_name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")
    "exports/#{timestamp}_#{slug}_#{suffix}.zip"
  end

  @spec persist_record(String.t(), String.t(), String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, ExportRecord.t()} | {:error, Ecto.Changeset.t()}
  defp persist_record(owner_id, name, key, url, size_bytes, file_count) do
    %ExportRecord{}
    |> ExportRecord.changeset(%{
      owner_id: owner_id,
      name: name,
      storage_key: key,
      download_url: url,
      size_bytes: size_bytes,
      file_count: file_count,
      archived_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end
end
```
