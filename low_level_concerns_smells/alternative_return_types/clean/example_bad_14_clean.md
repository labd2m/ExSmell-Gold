```elixir
defmodule MyApp.Exports.DataExporter do
  @moduledoc """
  Exports domain data snapshots to various formats and delivery destinations.
  Used by the admin dashboard for bulk data downloads, scheduled reporting
  jobs, and compliance archiving pipelines.
  """

  alias MyApp.Exports.CsvEncoder
  alias MyApp.Exports.JsonEncoder
  alias MyApp.Exports.XlsxEncoder
  alias MyApp.Exports.StorageAdapter
  alias MyApp.Exports.CompressionUtil

  @supported_formats [:csv, :json, :xlsx]
  @temp_dir "/tmp/exports"

  def build_options(format, delivery, opts \\ []) do
    [
      format: format,
      delivery: delivery,
      compress: Keyword.get(opts, :compress, false),
      filename: Keyword.get(opts, :filename, default_filename(format))
    ]
  end

  def export(data, schema, opts \\ []) when is_list(opts) do
    format = Keyword.get(opts, :format, :csv)
    delivery = Keyword.get(opts, :delivery, :memory)
    compress = Keyword.get(opts, :compress, false)
    filename = Keyword.get(opts, :filename, default_filename(format))

    unless format in @supported_formats do
      raise ArgumentError, "unsupported format: #{inspect(format)}"
    end

    encoded =
      case format do
        :csv -> CsvEncoder.encode(data, schema)
        :json -> JsonEncoder.encode(data, schema)
        :xlsx -> XlsxEncoder.encode(data, schema)
      end

    final_bytes = if compress, do: CompressionUtil.gzip(encoded), else: encoded

    case delivery do
      :memory ->
        {:ok, final_bytes}

      :disk ->
        path = Path.join(@temp_dir, filename)
        File.mkdir_p!(Path.dirname(path))

        case File.write(path, final_bytes) do
          :ok -> {:ok, path}
          {:error, reason} -> {:error, {:write_failed, reason}}
        end

      :upload ->
        bucket = Application.fetch_env!(:my_app, :export_bucket)
        key = "exports/#{filename}"

        case StorageAdapter.put(bucket, key, final_bytes) do
          {:ok, url} -> {:ok, url}
          {:error, reason} -> {:error, {:upload_failed, reason}}
        end
    end
  end

  def cleanup_disk_exports(older_than_hours \\ 24) do
    cutoff = DateTime.add(DateTime.utc_now(), -older_than_hours * 3600, :second)

    @temp_dir
    |> File.ls!()
    |> Enum.each(fn file ->
      path = Path.join(@temp_dir, file)
      stat = File.stat!(path, time: :posix)
      mtime = DateTime.from_unix!(stat.mtime)

      if DateTime.compare(mtime, cutoff) == :lt do
        File.rm!(path)
      end
    end)
  end

  def supported_formats, do: @supported_formats

  defp default_filename(format) do
    ts = DateTime.utc_now() |> DateTime.to_unix()
    "export_#{ts}.#{format}"
  end
end
```
