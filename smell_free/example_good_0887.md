```elixir
defmodule Releases.ChangelogGenerator do
  @moduledoc """
  Parses Git commit messages following the Conventional Commits specification
  and generates a structured changelog grouped by change type. The generator
  is intentionally pure: it receives a list of raw commit strings and returns
  a structured map, making it easy to test and compose with different input
  sources (Git CLI, GitHub API, pre-fetched logs).
  """

  @type raw_commit :: binary()
  @type parsed_commit :: %{
          type: binary(),
          scope: binary() | nil,
          description: binary(),
          breaking: boolean(),
          hash: binary() | nil
        }

  @type changelog :: %{
          version: binary(),
          breaking_changes: [parsed_commit()],
          features: [parsed_commit()],
          fixes: [parsed_commit()],
          improvements: [parsed_commit()],
          other: [parsed_commit()]
        }

  @known_types %{
    "feat" => :features,
    "fix" => :fixes,
    "perf" => :improvements,
    "refactor" => :improvements,
    "docs" => :other,
    "style" => :other,
    "test" => :other,
    "chore" => :other,
    "ci" => :other,
    "build" => :other,
    "revert" => :other
  }

  @commit_regex ~r/^(?<hash>[a-f0-9]{7,40}\s)?(?<type>\w+)(\((?<scope>[^)]+)\))?(?<breaking>!)?:\s(?<description>.+)$/

  @doc """
  Parses a list of raw commit message strings and returns a structured
  changelog for `version`. Unknown commit formats are silently skipped.
  """
  @spec generate(binary(), [raw_commit()]) :: changelog()
  def generate(version, raw_commits) when is_binary(version) and is_list(raw_commits) do
    parsed =
      raw_commits
      |> Enum.map(&parse_commit/1)
      |> Enum.reject(&is_nil/1)

    breaking = Enum.filter(parsed, & &1.breaking)
    features = commits_of_type(parsed, :features)
    fixes = commits_of_type(parsed, :fixes)
    improvements = commits_of_type(parsed, :improvements)
    other = commits_of_type(parsed, :other)

    %{
      version: version,
      breaking_changes: breaking,
      features: features,
      fixes: fixes,
      improvements: improvements,
      other: other
    }
  end

  @doc """
  Formats a `changelog` as a Markdown string suitable for `CHANGELOG.md`.
  """
  @spec to_markdown(changelog()) :: binary()
  def to_markdown(%{version: version} = changelog) do
    date = Date.utc_today() |> Date.to_string()
    sections = build_markdown_sections(changelog)

    header = "## [#{version}] - #{date}\n\n"
    header <> Enum.join(sections, "\n")
  end

  @doc """
  Returns `true` when any commit in `raw_commits` introduces a breaking change.
  Useful for determining whether a version bump should be major.
  """
  @spec has_breaking_changes?([raw_commit()]) :: boolean()
  def has_breaking_changes?(raw_commits) when is_list(raw_commits) do
    Enum.any?(raw_commits, fn commit ->
      case parse_commit(commit) do
        %{breaking: true} -> true
        _ -> false
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp parse_commit(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    case Regex.named_captures(@commit_regex, trimmed) do
      nil ->
        nil

      captures ->
        type = Map.get(captures, "type", "")
        breaking = Map.get(captures, "breaking", "") == "!" or String.contains?(trimmed, "BREAKING CHANGE")

        %{
          type: type,
          scope: blank_to_nil(Map.get(captures, "scope")),
          description: String.trim(Map.get(captures, "description", "")),
          breaking: breaking,
          hash: blank_to_nil(String.trim(Map.get(captures, "hash", "")))
        }
    end
  end

  defp commits_of_type(parsed, bucket) do
    Enum.filter(parsed, fn commit ->
      Map.get(@known_types, commit.type) == bucket
    end)
  end

  defp build_markdown_sections(changelog) do
    sections = [
      {changelog.breaking_changes, "### ⚠ Breaking Changes"},
      {changelog.features, "### Features"},
      {changelog.fixes, "### Bug Fixes"},
      {changelog.improvements, "### Improvements"},
      {changelog.other, "### Other Changes"}
    ]

    sections
    |> Enum.reject(fn {commits, _} -> Enum.empty?(commits) end)
    |> Enum.map(fn {commits, heading} ->
      lines = Enum.map(commits, &format_commit_line/1)
      "#{heading}\n\n#{Enum.join(lines, "\n")}\n"
    end)
  end

  defp format_commit_line(%{description: desc, scope: nil, hash: nil}), do: "- #{desc}"
  defp format_commit_line(%{description: desc, scope: scope, hash: nil}) when not is_nil(scope), do: "- **#{scope}:** #{desc}"
  defp format_commit_line(%{description: desc, scope: nil, hash: hash}), do: "- #{desc} (#{hash})"
  defp format_commit_line(%{description: desc, scope: scope, hash: hash}), do: "- **#{scope}:** #{desc} (#{hash})"

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: value
end
```
