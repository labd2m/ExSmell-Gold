```elixir
defmodule Releases.ChangelogBuilder do
  @moduledoc """
  Parses a list of Conventional Commits-formatted commit messages and
  produces a structured changelog grouped by type. Supports semver bump
  inference from the commit set.
  """

  @type commit :: %{
          hash: String.t(),
          message: String.t(),
          author: String.t(),
          date: Date.t()
        }

  @type parsed_commit :: %{
          hash: String.t(),
          type: String.t(),
          scope: String.t() | nil,
          description: String.t(),
          breaking: boolean(),
          author: String.t(),
          date: Date.t()
        }

  @type changelog :: %{
          version: String.t(),
          bump: :major | :minor | :patch,
          sections: %{String.t() => [parsed_commit()]},
          date: Date.t()
        }

  @feat_types ~w[feat feature]
  @fix_types ~w[fix bugfix]
  @display_order ~w[feat fix perf refactor docs chore test]

  @spec build([commit()], String.t()) :: {:ok, changelog()} | {:error, :no_commits}
  def build([], _current_version), do: {:error, :no_commits}

  def build(commits, current_version) when is_list(commits) do
    parsed = Enum.map(commits, &parse_commit/1)
    bump = infer_bump(parsed)
    next_version = bump_version(current_version, bump)
    sections = group_by_type(parsed)

    {:ok,
     %{
       version: next_version,
       bump: bump,
       sections: sections,
       date: Date.utc_today()
     }}
  end

  @spec render_markdown(changelog()) :: String.t()
  def render_markdown(%{version: version, date: date, sections: sections}) do
    header = "## [#{version}] - #{Date.to_iso8601(date)}\n\n"

    body =
      @display_order
      |> Enum.filter(&Map.has_key?(sections, &1))
      |> Enum.map(fn type ->
        items = Map.fetch!(sections, type)
        section_header = "### #{section_title(type)}\n\n"
        lines = Enum.map(items, &format_entry/1) |> Enum.join("\n")
        section_header <> lines <> "\n"
      end)
      |> Enum.join("\n")

    header <> body
  end

  @spec parse_commit(commit()) :: parsed_commit()
  defp parse_commit(%{message: message} = commit) do
    {type, scope, description, breaking} = extract_conventional(message)

    %{
      hash: commit.hash,
      type: type,
      scope: scope,
      description: description,
      breaking: breaking,
      author: commit.author,
      date: commit.date
    }
  end

  @spec extract_conventional(String.t()) :: {String.t(), String.t() | nil, String.t(), boolean()}
  defp extract_conventional(message) do
    pattern = ~r/^(?<type>[a-z]+)(?:\((?<scope>[^)]+)\))?(?<breaking>!)?:\s*(?<desc>.+)$/

    case Regex.named_captures(pattern, String.trim(message)) do
      %{"type" => type, "scope" => scope, "breaking" => breaking, "desc" => desc} ->
        {type, if(scope == "", do: nil, else: scope), desc, breaking == "!"}

      nil ->
        {"chore", nil, message, false}
    end
  end

  @spec infer_bump([parsed_commit()]) :: :major | :minor | :patch
  defp infer_bump(commits) do
    cond do
      Enum.any?(commits, & &1.breaking) -> :major
      Enum.any?(commits, &(&1.type in @feat_types)) -> :minor
      true -> :patch
    end
  end

  @spec bump_version(String.t(), :major | :minor | :patch) :: String.t()
  defp bump_version(current, bump) do
    case String.split(current, ".") do
      [major, minor, patch] ->
        {mj, _} = Integer.parse(major)
        {mn, _} = Integer.parse(minor)
        {pt, _} = Integer.parse(patch)

        case bump do
          :major -> "#{mj + 1}.0.0"
          :minor -> "#{mj}.#{mn + 1}.0"
          :patch -> "#{mj}.#{mn}.#{pt + 1}"
        end

      _ ->
        "0.1.0"
    end
  end

  @spec group_by_type([parsed_commit()]) :: %{String.t() => [parsed_commit()]}
  defp group_by_type(commits) do
    Enum.group_by(commits, & &1.type)
  end

  @spec format_entry(parsed_commit()) :: String.t()
  defp format_entry(%{scope: nil, description: desc, hash: hash}) do
    "- #{desc} (`#{String.slice(hash, 0, 7)}`)"
  end

  defp format_entry(%{scope: scope, description: desc, hash: hash}) do
    "- **#{scope}**: #{desc} (`#{String.slice(hash, 0, 7)}`)"
  end

  @spec section_title(String.t()) :: String.t()
  defp section_title("feat"), do: "Features"
  defp section_title("feature"), do: "Features"
  defp section_title("fix"), do: "Bug Fixes"
  defp section_title("bugfix"), do: "Bug Fixes"
  defp section_title("perf"), do: "Performance"
  defp section_title("refactor"), do: "Refactoring"
  defp section_title("docs"), do: "Documentation"
  defp section_title("chore"), do: "Chores"
  defp section_title("test"), do: "Tests"
  defp section_title(type), do: String.capitalize(type)
end
```
