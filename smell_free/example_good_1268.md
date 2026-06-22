```elixir
defmodule Media.Variant do
  @moduledoc """
  Describes a single derived media variant, such as a thumbnail or
  a transcoded video rendition, produced from an original uploaded file.
  """

  @enforce_keys [:key, :width, :height, :format]
  defstruct [:key, :width, :height, :format, :quality, :url]

  @type format :: :webp | :jpeg | :png | :avif
  @type t :: %__MODULE__{
          key: atom(),
          width: pos_integer(),
          height: pos_integer(),
          format: format(),
          quality: 1..100 | nil,
          url: String.t() | nil
        }

  @spec new(atom(), pos_integer(), pos_integer(), format(), keyword()) :: t()
  def new(key, width, height, format, opts \\ [])
      when is_atom(key) and is_integer(width) and width > 0 and
             is_integer(height) and height > 0 and format in [:webp, :jpeg, :png, :avif] do
    %__MODULE__{
      key: key,
      width: width,
      height: height,
      format: format,
      quality: Keyword.get(opts, :quality),
      url: Keyword.get(opts, :url)
    }
  end
end

defmodule Media.VariantSet do
  @moduledoc """
  A named collection of variant specifications for a media processing profile.
  Profiles are declared by name and resolved at runtime.
  """

  alias Media.Variant

  @profiles %{
    image: [
      Variant.new(:thumbnail, 200, 200, :webp, quality: 80),
      Variant.new(:medium, 800, 600, :webp, quality: 85),
      Variant.new(:large, 1920, 1080, :webp, quality: 90)
    ],
    avatar: [
      Variant.new(:small, 40, 40, :webp, quality: 85),
      Variant.new(:medium, 80, 80, :webp, quality: 85),
      Variant.new(:large, 200, 200, :webp, quality: 90)
    ]
  }

  @spec for_profile(atom()) :: {:ok, list(Variant.t())} | {:error, :unknown_profile}
  def for_profile(profile) when is_atom(profile) do
    case Map.fetch(@profiles, profile) do
      {:ok, variants} -> {:ok, variants}
      :error -> {:error, :unknown_profile}
    end
  end

  @spec all_profiles() :: list(atom())
  def all_profiles, do: Map.keys(@profiles)
end

defmodule Media.Processor do
  @moduledoc """
  Orchestrates derivative generation for an uploaded media file.
  Each variant is processed independently so a single failure does not
  abort the entire set. Results are collected as tagged per-variant outcomes.
  """

  alias Media.{Variant, VariantSet}

  @type source :: %{path: String.t(), content_type: String.t()}
  @type process_outcome :: %{variant: Variant.t(), result: {:ok, String.t()} | {:error, term()}}

  @spec process(source(), atom(), String.t()) ::
          {:ok, list(process_outcome())} | {:error, :unknown_profile}
  def process(%{path: path, content_type: ct}, profile, output_dir)
      when is_binary(path) and is_binary(ct) and is_atom(profile) and is_binary(output_dir) do
    with {:ok, variants} <- VariantSet.for_profile(profile) do
      outcomes =
        Enum.map(variants, fn variant ->
          result = generate_variant(path, variant, output_dir)
          %{variant: variant, result: result}
        end)

      {:ok, outcomes}
    end
  end

  @spec succeeded(list(process_outcome())) :: list(process_outcome())
  def succeeded(outcomes) when is_list(outcomes) do
    Enum.filter(outcomes, &match?(%{result: {:ok, _}}, &1))
  end

  @spec failed(list(process_outcome())) :: list(process_outcome())
  def failed(outcomes) when is_list(outcomes) do
    Enum.filter(outcomes, &match?(%{result: {:error, _}}, &1))
  end

  defp generate_variant(source_path, %Variant{} = variant, output_dir) do
    dest = output_path(source_path, variant, output_dir)

    conversion_args = build_args(variant)

    case System.cmd("convert", [source_path | conversion_args] ++ [dest], stderr_to_stdout: true) do
      {_output, 0} -> {:ok, dest}
      {error, code} -> {:error, {:conversion_failed, code, error}}
    end
  rescue
    err -> {:error, {:exception, Exception.message(err)}}
  end

  defp build_args(%Variant{width: w, height: h, quality: nil}) do
    ["-resize", "#{w}x#{h}^", "-gravity", "center", "-extent", "#{w}x#{h}"]
  end

  defp build_args(%Variant{width: w, height: h, quality: q}) do
    ["-resize", "#{w}x#{h}^", "-gravity", "center", "-extent", "#{w}x#{h}", "-quality", to_string(q)]
  end

  defp output_path(source_path, %Variant{key: key, format: format}, dir) do
    base = source_path |> Path.basename() |> Path.rootname()
    Path.join(dir, "#{base}_#{key}.#{format}")
  end
end
```
