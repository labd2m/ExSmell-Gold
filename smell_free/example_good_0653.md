```elixir
defmodule MyAppWeb.Pagination do
  @moduledoc """
  Shared pagination helpers for Phoenix controllers and LiveViews.
  Extracts and validates pagination parameters from request query strings,
  builds typed pagination structs, and computes the metadata required by
  API response envelopes and HTML pagination UI components. Pagination
  parameters are validated to sensible bounds so callers cannot request
  negative pages or absurdly large page sizes.
  """

  @type params :: %{optional(binary()) => binary()}

  @type pagination :: %{
          page: pos_integer(),
          per_page: pos_integer(),
          offset: non_neg_integer()
        }

  @type page_meta :: %{
          page: pos_integer(),
          per_page: pos_integer(),
          total_count: non_neg_integer(),
          total_pages: non_neg_integer(),
          has_prev: boolean(),
          has_next: boolean(),
          first_item: non_neg_integer(),
          last_item: non_neg_integer()
        }

  @default_per_page 25
  @max_per_page 200
  @min_per_page 1

  @doc """
  Extracts and validates `page` and `per_page` from `params`.
  Returns a `pagination()` struct with a pre-computed `offset`.
  Invalid values are clamped to sane defaults rather than rejected,
  so API clients with off-by-one bugs still receive a sensible response.
  """
  @spec from_params(params()) :: pagination()
  def from_params(params) when is_map(params) do
    page = params |> Map.get("page", "1") |> parse_positive_integer(1)
    per_page = params |> Map.get("per_page", to_string(@default_per_page)) |> parse_per_page()

    %{
      page: page,
      per_page: per_page,
      offset: (page - 1) * per_page
    }
  end

  @doc """
  Computes pagination metadata given a `pagination` struct and the
  `total_count` of matching records. Returns a `page_meta()` map
  suitable for embedding in API response envelopes.
  """
  @spec meta(pagination(), non_neg_integer()) :: page_meta()
  def meta(%{page: page, per_page: per_page}, total_count)
      when is_integer(total_count) and total_count >= 0 do
    total_pages = max(1, ceil_div(total_count, per_page))
    first_item = if total_count == 0, do: 0, else: (page - 1) * per_page + 1
    last_item = min(page * per_page, total_count)

    %{
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      has_prev: page > 1,
      has_next: page < total_pages,
      first_item: first_item,
      last_item: last_item
    }
  end

  @doc """
  Renders pagination metadata as a JSON-compatible map for API responses.
  Conforms to the RFC 5988 link relations style used by GitHub, Stripe, etc.
  """
  @spec to_json_envelope(list(), page_meta()) :: map()
  def to_json_envelope(data, meta) do
    %{
      data: data,
      meta: %{
        current_page: meta.page,
        per_page: meta.per_page,
        total_count: meta.total_count,
        total_pages: meta.total_pages
      },
      links: build_links(meta)
    }
  end

  @doc """
  Returns a `Range.t()` of page numbers for rendering a windowed page
  selector (e.g., pages 3-7 of 20). The window is centred on `current_page`.
  """
  @spec page_window(page_meta(), pos_integer()) :: Range.t()
  def page_window(%{page: page, total_pages: total}, window_size \\ 5) do
    half = div(window_size, 2)
    raw_start = max(1, page - half)
    raw_end = min(total, raw_start + window_size - 1)
    adjusted_start = max(1, raw_end - window_size + 1)
    adjusted_start..raw_end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp parse_positive_integer(raw, default) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_per_page(raw) do
    parse_positive_integer(raw, @default_per_page)
    |> max(@min_per_page)
    |> min(@max_per_page)
  end

  defp build_links(%{page: page, total_pages: total} = meta) do
    base = %{}

    base
    |> maybe_put_link(:first, 1)
    |> maybe_put_link(:last, total)
    |> maybe_put_link(:prev, if(meta.has_prev, do: page - 1))
    |> maybe_put_link(:next, if(meta.has_next, do: page + 1))
  end

  defp maybe_put_link(map, _rel, nil), do: map
  defp maybe_put_link(map, rel, page), do: Map.put(map, rel, "?page=#{page}")

  defp ceil_div(_total, 0), do: 1
  defp ceil_div(total, per_page), do: ceil(total / per_page)
end
```
