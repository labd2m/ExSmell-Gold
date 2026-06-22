```elixir
defmodule Analytics.HeatmapAggregator do
  @moduledoc """
  Aggregates raw click and scroll interaction events into a spatial
  heat-map grid. The grid divides a normalised coordinate space (0–1
  on each axis) into configurable cell counts. Each interaction event
  increments the intensity of the cell it falls within. The aggregator
  produces a flat list of cells with their positions and intensities,
  suitable for rendering or exporting.
  """

  @type coordinate :: float()
  @type interaction :: %{x: coordinate(), y: coordinate(), weight: pos_integer()}
  @type cell :: %{
          col: non_neg_integer(),
          row: non_neg_integer(),
          x_center: float(),
          y_center: float(),
          intensity: non_neg_integer()
        }
  @type heatmap :: %{
          cols: pos_integer(),
          rows: pos_integer(),
          max_intensity: non_neg_integer(),
          cells: [cell()]
        }

  @default_cols 20
  @default_rows 15

  @doc """
  Aggregates `interactions` into a heat-map grid. `cols` and `rows` control
  the grid resolution. Returns a map with all cells sorted top-left to
  bottom-right, with normalised intensities available via `max_intensity`.
  """
  @spec aggregate([interaction()], pos_integer(), pos_integer()) :: heatmap()
  def aggregate(interactions, cols \\ @default_cols, rows \\ @default_rows)
      when is_list(interactions) and is_integer(cols) and cols > 0
      and is_integer(rows) and rows > 0 do
    grid = build_empty_grid(cols, rows)

    filled =
      Enum.reduce(interactions, grid, fn %{x: x, y: y, weight: w}, acc ->
        col = clamp(floor(x * cols), 0, cols - 1)
        row = clamp(floor(y * rows), 0, rows - 1)
        Map.update!(acc, {col, row}, &(&1 + w))
      end)

    max_intensity = filled |> Map.values() |> Enum.max(fn -> 0 end)

    cells =
      for row <- 0..(rows - 1), col <- 0..(cols - 1) do
        intensity = Map.get(filled, {col, row}, 0)

        %{
          col: col,
          row: row,
          x_center: (col + 0.5) / cols,
          y_center: (row + 0.5) / rows,
          intensity: intensity
        }
      end

    %{cols: cols, rows: rows, max_intensity: max_intensity, cells: cells}
  end

  @doc "Returns cells whose intensity is above `threshold` percent of the maximum."
  @spec hot_cells(heatmap(), float()) :: [cell()]
  def hot_cells(%{cells: cells, max_intensity: max}, threshold_pct)
      when is_float(threshold_pct) and threshold_pct >= 0.0 and threshold_pct <= 100.0 do
    cutoff = max * threshold_pct / 100
    Enum.filter(cells, fn c -> c.intensity >= cutoff end)
  end

  @doc "Normalises cell intensities to the 0.0–1.0 range for rendering."
  @spec normalise(heatmap()) :: [%{cell() | {:normalised_intensity, float()}}]
  def normalise(%{cells: cells, max_intensity: 0}), do: Enum.map(cells, &Map.put(&1, :normalised_intensity, 0.0))

  def normalise(%{cells: cells, max_intensity: max}) do
    Enum.map(cells, fn cell ->
      Map.put(cell, :normalised_intensity, Float.round(cell.intensity / max, 4))
    end)
  end

  defp build_empty_grid(cols, rows) do
    for col <- 0..(cols - 1), row <- 0..(rows - 1), into: %{} do
      {{col, row}, 0}
    end
  end

  defp clamp(value, min, max) do
    value |> max(min) |> min(max)
  end
end
```
