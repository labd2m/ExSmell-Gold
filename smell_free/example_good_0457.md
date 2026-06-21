```elixir
defmodule MyApp.Content.TagNormalizer do
  @moduledoc """
  Normalises user-submitted tag strings into consistent, URL-safe slugs
  and enforces catalogue-level constraints. Tags are deduplicated,
  trimmed, lower-cased, and filtered against a configurable blocklist
  before being returned as a canonical list.

  All functions are pure and operate entirely in memory, making this
  module trivially fast and testable without any process setup.
  """

  @max_tag_length 50
  @max_tags_per_resource 20
  @min_tag_length 2

  @blocklist ~w(
    admin system root superuser internal
    moderator staff support ops engineer
  )

  @type raw_tag :: String.t()
  @type normalised_tag :: String.t()
  @type normalisation_result :: %{
          tags: [normalised_tag()],
          rejected: [%{raw: raw_tag(), reason: atom()}]
        }

  @doc """
  Normalises `raw_tags` and returns a result map with accepted tags and
  rejected entries annotated with the rejection reason. The accepted
  list never exceeds #{@max_tags_per_resource} unique entries.
  """
  @spec normalise([raw_tag()]) :: normalisation_result()
  def normalise(raw_tags) when is_list(raw_tags) do
    {accepted, rejected} =
      raw_tags
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&process_tag/1)
      |> Enum.reduce({[], []}, fn
        {:ok, tag}, {acc_ok, acc_err} -> {[tag | acc_ok], acc_err}
        {:error, raw, reason}, {acc_ok, acc_err} -> {acc_ok, [%{raw: raw, reason: reason} | acc_err]}
      end)

    unique = accepted |> Enum.uniq() |> Enum.take(@max_tags_per_resource)

    %{tags: Enum.reverse(unique), rejected: Enum.reverse(rejected)}
  end

  @doc """
  Merges two tag lists, normalising both inputs and returning a
  deduplicated result capped at the maximum tag count.
  """
  @spec merge([raw_tag()], [raw_tag()]) :: [normalised_tag()]
  def merge(existing, additions) when is_list(existing) and is_list(additions) do
    %{tags: existing_tags} = normalise(existing)
    %{tags: new_tags} = normalise(additions)

    (existing_tags ++ new_tags)
    |> Enum.uniq()
    |> Enum.take(@max_tags_per_resource)
  end

  @spec process_tag(raw_tag()) :: {:ok, normalised_tag()} | {:error, raw_tag(), atom()}
  defp process_tag(raw) do
    slug = slugify(raw)

    cond do
      String.length(slug) < @min_tag_length ->
        {:error, raw, :too_short}

      String.length(slug) > @max_tag_length ->
        {:error, raw, :too_long}

      slug in @blocklist ->
        {:error, raw, :blocklisted}

      not valid_slug?(slug) ->
        {:error, raw, :invalid_characters}

      true ->
        {:ok, slug}
    end
  end

  @spec slugify(raw_tag()) :: normalised_tag()
  defp slugify(str) do
    str
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^\x00-\x7F]/, "")
    |> String.replace(~r/[^a-z0-9\s\-]/, "")
    |> String.replace(~r/[\s]+/, "-")
    |> String.trim("-")
  end

  @spec valid_slug?(String.t()) :: boolean()
  defp valid_slug?(str), do: String.match?(str, ~r/\A[a-z0-9][a-z0-9\-]*[a-z0-9]\z/)
end
```
