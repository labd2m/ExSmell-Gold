```elixir
defmodule Geo.Fencing do
  @moduledoc """
  Evaluates whether geographic coordinates fall within named fence polygons.

  Fences are defined as ordered lists of latitude/longitude vertices. Point
  containment is determined using the ray-casting algorithm. All geometry
  operations are pure functions with no external dependencies.
  """

  alias Geo.Fencing.{Fence, Point, ContainmentResult}

  @doc """
  Checks whether a point falls inside any of the given fences.

  Returns a list of `ContainmentResult` structs, one per fence.
  """
  @spec check(Point.t(), [Fence.t()]) :: [ContainmentResult.t()]
  def check(%Point{} = point, fences) when is_list(fences) do
    Enum.map(fences, fn fence ->
      contained = contains?(fence, point)
      ContainmentResult.new(fence.id, fence.name, contained)
    end)
  end

  @doc """
  Returns only the fences that contain the given point.
  """
  @spec matching_fences(Point.t(), [Fence.t()]) :: [Fence.t()]
  def matching_fences(%Point{} = point, fences) when is_list(fences) do
    Enum.filter(fences, &contains?(&1, point))
  end

  @doc """
  Determines whether a point is inside a single fence polygon.
  """
  @spec contains?(Fence.t(), Point.t()) :: boolean()
  def contains?(%Fence{vertices: vertices}, %Point{lat: lat, lng: lng})
      when length(vertices) >= 3 do
    ray_cast(lat, lng, vertices, false)
  end

  def contains?(%Fence{}, %Point{}), do: false

  # --- ray-casting algorithm ---

  defp ray_cast(_lat, _lng, [], inside), do: inside

  defp ray_cast(lat, lng, [_last], inside), do: inside

  defp ray_cast(lat, lng, vertices, inside) do
    pairs = Enum.zip(vertices, tl(vertices) ++ [hd(vertices)])

    new_inside =
      Enum.reduce(pairs, inside, fn {v1, v2}, acc ->
        if ray_intersects?(lat, lng, v1, v2), do: not acc, else: acc
      end)

    new_inside
  end

  defp ray_intersects?(lat, lng, %Point{lat: y1, lng: x1}, %Point{lat: y2, lng: x2}) do
    (y1 > lat) != (y2 > lat) and lng < (x2 - x1) * (lat - y1) / (y2 - y1) + x1
  end
end

defmodule Geo.Fencing.Point do
  @moduledoc "A geographic coordinate represented as latitude and longitude."

  @enforce_keys [:lat, :lng]
  defstruct [:lat, :lng]

  @type t :: %__MODULE__{lat: float(), lng: float()}

  @spec new(float(), float()) :: {:ok, t()} | {:error, String.t()}
  def new(lat, lng) when is_float(lat) and is_float(lng) and
        lat >= -90.0 and lat <= 90.0 and lng >= -180.0 and lng <= 180.0 do
    {:ok, %__MODULE__{lat: lat, lng: lng}}
  end

  def new(_, _), do: {:error, "lat must be -90..90 and lng must be -180..180"}
end

defmodule Geo.Fencing.Fence do
  @moduledoc "A named polygon fence described by an ordered list of coordinate vertices."

  @enforce_keys [:id, :name, :vertices]
  defstruct [:id, :name, :vertices]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          vertices: [Geo.Fencing.Point.t()]
        }

  @spec new(String.t(), String.t(), [Geo.Fencing.Point.t()]) ::
          {:ok, t()} | {:error, String.t()}
  def new(id, name, vertices)
      when is_binary(id) and is_binary(name) and is_list(vertices) and length(vertices) >= 3 do
    {:ok, %__MODULE__{id: id, name: name, vertices: vertices}}
  end

  def new(_, _, _), do: {:error, "a fence requires at least 3 vertices"}
end

defmodule Geo.Fencing.ContainmentResult do
  @moduledoc "Result of a single point-in-fence containment check."

  @enforce_keys [:fence_id, :fence_name, :contained]
  defstruct [:fence_id, :fence_name, :contained]

  @type t :: %__MODULE__{
          fence_id: String.t(),
          fence_name: String.t(),
          contained: boolean()
        }

  @spec new(String.t(), String.t(), boolean()) :: t()
  def new(fence_id, fence_name, contained) do
    %__MODULE__{fence_id: fence_id, fence_name: fence_name, contained: contained}
  end
end
```
