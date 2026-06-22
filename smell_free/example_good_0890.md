```elixir
defmodule Storage.DirectoryScanner do
  @moduledoc """
  Recursively scans a local directory tree, computing SHA-256 content hashes
  for every file in parallel. Results are returned as a flat list of file
  descriptors including path, size, modification time, and content hash.
  The scan is bounded by a configurable maximum concurrency to avoid
  exhausting file descriptors on very large trees. Symbolic links are
  detected and recorded separately to prevent infinite loops.
  """

  require Logger

  @type file_descriptor :: %{
          path: binary(),
          relative_path: binary(),
          size_bytes: non_neg_integer(),
          modified_at: DateTime.t(),
          sha256: binary(),
          symlink: boolean()
        }

  @type scan_opts :: [
          max_concurrency: pos_integer(),
          exclude_patterns: [Regex.t()],
          follow_symlinks: boolean()
        ]

  @type scan_result :: %{
          base_path: binary(),
          files: [file_descriptor()],
          total_size_bytes: non_neg_integer(),
          duration_ms: non_neg_integer()
        }

  @default_concurrency 16

  @doc """
  Scans `base_path` recursively and returns a `scan_result` map.
  File hashing is performed concurrently across up to `:max_concurrency` tasks.
  """
  @spec scan(binary(), scan_opts()) :: {:ok, scan_result()} | {:error, term()}
  def scan(base_path, opts \\ []) when is_binary(base_path) do
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_concurrency)
    exclude_patterns = Keyword.get(opts, :exclude_patterns, [])
    follow_symlinks = Keyword.get(opts, :follow_symlinks, false)

    started_at = System.monotonic_time(:millisecond)

    with {:ok, raw_entries} <- collect_entries(base_path, exclude_patterns, follow_symlinks) do
      file_descriptors =
        raw_entries
        |> Task.async_stream(
          fn entry -> hash_entry(entry, base_path) end,
          max_concurrency: max_concurrency,
          timeout: 60_000,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, descriptor} -> [descriptor]
          {:exit, :timeout} -> []
          {:exit, reason} ->
            Logger.warning("File hash task failed", reason: inspect(reason))
            []
        end)

      total_size = Enum.sum_by(file_descriptors, & &1.size_bytes)
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      Logger.info("Directory scan complete",
        base_path: base_path,
        file_count: length(file_descriptors),
        total_size_mb: Float.round(total_size / (1024 * 1024), 2),
        duration_ms: elapsed_ms
      )

      {:ok,
       %{
         base_path: base_path,
         files: Enum.sort_by(file_descriptors, & &1.relative_path),
         total_size_bytes: total_size,
         duration_ms: elapsed_ms
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp collect_entries(base_path, exclude_patterns, follow_symlinks) do
    case File.ls(base_path) do
      {:ok, names} ->
        entries =
          names
          |> Enum.map(&Path.join(base_path, &1))
          |> Enum.reject(&excluded?(&1, exclude_patterns))
          |> Enum.flat_map(&expand_entry(&1, exclude_patterns, follow_symlinks))

        {:ok, entries}

      {:error, reason} ->
        {:error, {:scan_failed, base_path, reason}}
    end
  end

  defp expand_entry(path, exclude_patterns, follow_symlinks) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case collect_entries(path, exclude_patterns, follow_symlinks) do
          {:ok, entries} -> entries
          _ -> []
        end

      {:ok, %File.Stat{type: :symlink}} when not follow_symlinks ->
        [%{path: path, symlink: true}]

      {:ok, %File.Stat{type: :regular}} ->
        [%{path: path, symlink: false}]

      _ ->
        []
    end
  end

  defp hash_entry(%{symlink: true, path: path} = entry, base_path) do
    %{
      path: path,
      relative_path: Path.relative_to(path, base_path),
      size_bytes: 0,
      modified_at: DateTime.utc_now(),
      sha256: nil,
      symlink: true
    }
  end

  defp hash_entry(%{path: path}, base_path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size, mtime: mtime}} ->
        sha256 = hash_file(path)
        modified_at = mtime |> :calendar.datetime_to_gregorian_seconds() |> to_datetime()

        %{
          path: path,
          relative_path: Path.relative_to(path, base_path),
          size_bytes: size,
          modified_at: modified_at,
          sha256: sha256,
          symlink: false
        }

      {:error, reason} ->
        Logger.warning("Could not stat file", path: path, reason: inspect(reason))
        nil
    end
  end

  defp hash_file(path) do
    path
    |> File.stream!([], 65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  rescue
    _ -> nil
  end

  defp excluded?(path, patterns) do
    name = Path.basename(path)
    Enum.any?(patterns, &Regex.match?(&1, name))
  end

  defp to_datetime(gregorian_seconds) do
    unix = gregorian_seconds - 62_167_219_200
    DateTime.from_unix!(unix)
  end
end
```
