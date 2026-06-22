```elixir
defmodule Media.ImageResizer do
  @moduledoc """
  Resizes images to predefined variant profiles using a system call to
  ImageMagick. Profiles specify the target geometry and output quality.
  Each resize operation is isolated: failures return a typed error without
  affecting other operations. The module is stateless and safe to call
  from any supervised task.
  """

  require Logger

  @type profile_name :: atom()
  @type profile :: %{
          width: pos_integer(),
          height: pos_integer(),
          quality: 1..100,
          fit: :cover | :contain | :fill
        }
  @type resize_result :: {:ok, Path.t()} | {:error, :conversion_failed | :source_not_found}

  @profiles %{
    thumbnail: %{width: 150, height: 150, quality: 85, fit: :cover},
    medium:    %{width: 600, height: 600, quality: 85, fit: :contain},
    large:     %{width: 1200, height: 900, quality: 90, fit: :contain},
    og_image:  %{width: 1200, height: 630, quality: 90, fit: :fill}
  }

  @doc """
  Resizes the image at `source_path` to the named `profile`, writing the
  result to `output_path`. Returns the output path on success.
  """
  @spec resize(Path.t(), Path.t(), profile_name()) :: resize_result()
  def resize(source_path, output_path, profile_name)
      when is_binary(source_path) and is_binary(output_path) and is_atom(profile_name) do
    case Map.get(@profiles, profile_name) do
      nil ->
        {:error, :conversion_failed}

      profile ->
        run_conversion(source_path, output_path, profile)
    end
  end

  @doc "Returns the configured profile map for `profile_name`, or nil if unknown."
  @spec profile(profile_name()) :: profile() | nil
  def profile(name) when is_atom(name), do: Map.get(@profiles, name)

  @doc "Returns all available profile names."
  @spec profile_names() :: [profile_name()]
  def profile_names, do: Map.keys(@profiles)

  @doc """
  Resizes `source_path` to all configured profiles, writing outputs to
  `output_dir/<profile_name>.<ext>`. Returns a map of profile to result.
  """
  @spec resize_all(Path.t(), Path.t()) :: %{profile_name() => resize_result()}
  def resize_all(source_path, output_dir) when is_binary(source_path) and is_binary(output_dir) do
    ext = source_path |> Path.extname() |> String.downcase()
    File.mkdir_p!(output_dir)

    Map.new(@profiles, fn {name, _profile} ->
      output_path = Path.join(output_dir, "#{name}#{ext}")
      {name, resize(source_path, output_path, name)}
    end)
  end

  defp run_conversion(source, output, %{width: w, height: h, quality: q, fit: fit}) do
    unless File.exists?(source) do
      {:error, :source_not_found}
    else
      geometry = build_geometry(w, h, fit)
      args = [source, "-resize", geometry, "-quality", Integer.to_string(q), output]

      case System.cmd("convert", args, stderr_to_stdout: true) do
        {_output, 0} ->
          {:ok, output}

        {err, code} ->
          Logger.warning("[ImageResizer] convert exited #{code}: #{String.slice(err, 0, 200)}")
          {:error, :conversion_failed}
      end
    end
  rescue
    e ->
      Logger.error("[ImageResizer] Unexpected error: #{Exception.message(e)}")
      {:error, :conversion_failed}
  end

  defp build_geometry(w, h, :cover), do: "#{w}x#{h}^"
  defp build_geometry(w, h, :contain), do: "#{w}x#{h}"
  defp build_geometry(w, h, :fill), do: "#{w}x#{h}!"
end
```
