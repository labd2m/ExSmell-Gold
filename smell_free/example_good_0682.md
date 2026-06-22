```elixir
defmodule QueryPlan.Result do
  @moduledoc false

  @type t :: %__MODULE__{
          plan_rows: [String.t()],
          total_cost: float() | nil,
          actual_time_ms: float() | nil,
          planning_time_ms: float() | nil,
          execution_time_ms: float() | nil,
          used_indexes: [String.t()],
          seq_scans: [String.t()]
        }

  defstruct [:total_cost, :actual_time_ms, :planning_time_ms, :execution_time_ms,
             plan_rows: [], used_indexes: [], seq_scans: []]
end

defmodule QueryPlan.Analyzer do
  @moduledoc """
  Captures and parses `EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)` output
  from PostgreSQL to surface query plan diagnostics.

  The analyzer is intended for use in development and staging environments
  to identify slow queries, missing indexes, and sequential scans on large
  tables. It wraps the given `Ecto.Query` inside an `EXPLAIN` statement
  executed via the Repo, then parses the textual output into a structured
  `QueryPlan.Result`.
  """

  alias QueryPlan.Result

  @spec analyze(Ecto.Query.t(), module()) :: {:ok, Result.t()} | {:error, term()}
  def analyze(%Ecto.Query{} = query, repo) do
    {sql, params} = Ecto.Adapters.SQL.to_sql(:all, repo, query)
    explain_sql = "EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) #{sql}"

    case repo.query(explain_sql, params) do
      {:ok, %{rows: rows}} ->
        plan_text = rows |> List.flatten() |> Enum.join("\n")
        {:ok, parse_plan(plan_text)}

      {:error, reason} ->
        {:error, {:explain_failed, reason}}
    end
  end

  @spec explain_string(Ecto.Query.t(), module()) :: {:ok, String.t()} | {:error, term()}
  def explain_string(%Ecto.Query{} = query, repo) do
    {sql, params} = Ecto.Adapters.SQL.to_sql(:all, repo, query)

    case repo.query("EXPLAIN #{sql}", params) do
      {:ok, %{rows: rows}} ->
        {:ok, rows |> List.flatten() |> Enum.join("\n")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec slow?(Result.t(), pos_integer()) :: boolean()
  def slow?(%Result{execution_time_ms: exec}, threshold_ms) when not is_nil(exec) do
    exec > threshold_ms
  end

  def slow?(_result, _threshold), do: false

  @spec has_seq_scans?(Result.t()) :: boolean()
  def has_seq_scans?(%Result{seq_scans: scans}), do: scans != []

  defp parse_plan(text) when is_binary(text) do
    lines = String.split(text, "\n")

    %Result{
      plan_rows: lines,
      total_cost: extract_float(text, ~r/cost=[\d.]+\.\.([\d.]+)/),
      actual_time_ms: extract_float(text, ~r/actual time=[\d.]+\.\.([\d.]+)/),
      planning_time_ms: extract_float(text, ~r/Planning Time: ([\d.]+) ms/),
      execution_time_ms: extract_float(text, ~r/Execution Time: ([\d.]+) ms/),
      used_indexes: extract_all(text, ~r/Index (?:Scan|Only Scan) using (\S+)/),
      seq_scans: extract_all(text, ~r/Seq Scan on (\S+)/)
    }
  end

  defp extract_float(text, pattern) do
    case Regex.run(pattern, text) do
      [_, value] ->
        case Float.parse(value) do
          {f, ""} -> f
          _ -> nil
        end

      nil ->
        nil
    end
  end

  defp extract_all(text, pattern) do
    Regex.scan(pattern, text) |> Enum.map(&List.last/1) |> Enum.uniq()
  end
end
```
