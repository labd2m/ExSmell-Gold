```elixir
defmodule SemVer do
  @moduledoc """
  Parses and compares Semantic Versioning 2.0.0 version strings.

  Pre-release identifiers follow SemVer precedence rules: numeric identifiers
  are compared as integers; alphanumeric identifiers are compared
  lexicographically. Build metadata is ignored for comparison purposes.
  """

  @type t :: %__MODULE__{
          major: non_neg_integer(),
          minor: non_neg_integer(),
          patch: non_neg_integer(),
          pre_release: [String.t() | integer()],
          build: String.t() | nil
        }

  defstruct [:major, :minor, :patch, :build, pre_release: []]

  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_version}
  def parse(version) when is_binary(version) do
    case Regex.run(
           ~r/\A(\d+)\.(\d+)\.(\d+)(?:-([a-zA-Z0-9.\-]+))?(?:\+([a-zA-Z0-9.\-]+))?\z/,
           version
         ) do
      [_, major, minor, patch | rest] ->
        {pre_str, build_str} = parse_optional(rest)

        {:ok,
         %__MODULE__{
           major: String.to_integer(major),
           minor: String.to_integer(minor),
           patch: String.to_integer(patch),
           pre_release: parse_pre_release(pre_str),
           build: build_str
         }}

      nil ->
        {:error, :invalid_version}
    end
  end

  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{} = a, %__MODULE__{} = b) do
    compare_fields(
      [a.major, a.minor, a.patch],
      [b.major, b.minor, b.patch],
      a.pre_release,
      b.pre_release
    )
  end

  @spec satisfies?(t(), String.t()) :: boolean()
  def satisfies?(%__MODULE__{} = version, constraint) when is_binary(constraint) do
    case parse_constraint(constraint) do
      {:ok, {op, required}} -> apply_constraint(op, compare(version, required))
      {:error, _} -> false
    end
  end

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{major: maj, minor: min, patch: pat, pre_release: pre, build: build}) do
    base = "#{maj}.#{min}.#{pat}"
    with_pre = if pre == [], do: base, else: "#{base}-#{Enum.join(pre, ".")}"
    if build, do: "#{with_pre}+#{build}", else: with_pre
  end

  defp compare_fields([h1 | t1], [h2 | t2], pre1, pre2) do
    cond do
      h1 < h2 -> :lt
      h1 > h2 -> :gt
      true -> compare_fields(t1, t2, pre1, pre2)
    end
  end

  defp compare_fields([], [], [], [_ | _]), do: :gt
  defp compare_fields([], [], [_ | _], []), do: :lt
  defp compare_fields([], [], [], []), do: :eq

  defp compare_fields([], [], [id1 | rest1], [id2 | rest2]) do
    cond do
      is_integer(id1) and is_integer(id2) and id1 < id2 -> :lt
      is_integer(id1) and is_integer(id2) and id1 > id2 -> :gt
      is_binary(id1) and is_binary(id2) -> if id1 < id2, do: :lt, else: if id1 > id2, do: :gt, else: compare_fields([], [], rest1, rest2)
      is_integer(id1) -> :lt
      true -> :gt
    end
  end

  defp parse_pre_release(nil), do: []
  defp parse_pre_release(""), do: []
  defp parse_pre_release(str) do
    Enum.map(String.split(str, "."), fn part ->
      case Integer.parse(part) do
        {n, ""} -> n
        _ -> part
      end
    end)
  end

  defp parse_optional([]), do: {nil, nil}
  defp parse_optional([pre | []]), do: {pre, nil}
  defp parse_optional([pre, build | _]), do: {pre, build}

  defp parse_constraint(">= " <> v), do: with {:ok, ver} <- parse(v), do: {:ok, {:gte, ver}}
  defp parse_constraint("> " <> v), do: with {:ok, ver} <- parse(v), do: {:ok, {:gt, ver}}
  defp parse_constraint("<= " <> v), do: with {:ok, ver} <- parse(v), do: {:ok, {:lte, ver}}
  defp parse_constraint("< " <> v), do: with {:ok, ver} <- parse(v), do: {:ok, {:lt, ver}}
  defp parse_constraint("= " <> v), do: with {:ok, ver} <- parse(v), do: {:ok, {:eq, ver}}
  defp parse_constraint(_), do: {:error, :invalid_constraint}

  defp apply_constraint(:gte, :gt), do: true
  defp apply_constraint(:gte, :eq), do: true
  defp apply_constraint(:gt, :gt), do: true
  defp apply_constraint(:lte, :lt), do: true
  defp apply_constraint(:lte, :eq), do: true
  defp apply_constraint(:lt, :lt), do: true
  defp apply_constraint(:eq, :eq), do: true
  defp apply_constraint(_, _), do: false
end
```
