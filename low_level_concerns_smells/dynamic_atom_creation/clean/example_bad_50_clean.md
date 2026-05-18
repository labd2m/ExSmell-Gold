```elixir
defmodule Workflow.StateMachineLoader do
  @moduledoc """
  Loads workflow state machine definitions from YAML configuration files
  and builds runtime transition tables used by the workflow engine.
  Definitions can be reloaded at runtime without application restart.
  """

  require Logger

  alias Workflow.{TransitionTable, GuardRegistry, ActionRegistry, SchemaValidator}

  @definitions_dir "priv/workflows"
  @schema_version "1.0"

  @spec load_all() :: {:ok, map()} | {:error, term()}
  def load_all do
    Logger.info("Loading workflow definitions", dir: @definitions_dir)

    with {:ok, files} <- list_definition_files(),
         {:ok, definitions} <- parse_files(files),
         :ok <- validate_all(definitions),
         {:ok, table} <- build_transition_table(definitions) do
      Logger.info("Workflow definitions loaded", count: map_size(definitions))
      {:ok, table}
    end
  end

  @spec reload(String.t()) :: {:ok, map()} | {:error, term()}
  def reload(workflow_name) do
    path = Path.join(@definitions_dir, "#{workflow_name}.yaml")

    with {:ok, raw} <- YamlElixir.read_from_file(path),
         {:ok, definition} <- parse_definition(workflow_name, raw),
         :ok <- SchemaValidator.validate(definition),
         {:ok, transitions} <- compile_transitions(definition) do
      TransitionTable.update(workflow_name, transitions)
      Logger.info("Workflow reloaded", workflow: workflow_name)
      {:ok, transitions}
    end
  end

  defp list_definition_files do
    case File.ls(@definitions_dir) do
      {:ok, files} ->
        yaml_files =
          files
          |> Enum.filter(&String.ends_with?(&1, ".yaml"))
          |> Enum.map(&Path.join(@definitions_dir, &1))

        {:ok, yaml_files}

      {:error, reason} ->
        {:error, {:directory_read_failed, reason}}
    end
  end

  defp parse_files(files) do
    results =
      Enum.map(files, fn path ->
        name = path |> Path.basename() |> Path.rootname()

        case YamlElixir.read_from_file(path) do
          {:ok, raw} -> parse_definition(name, raw)
          {:error, reason} -> {:error, {path, reason}}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      definitions =
        results
        |> Enum.map(fn {:ok, {name, def}} -> {name, def} end)
        |> Map.new()

      {:ok, definitions}
    else
      {:error, {:parse_errors, errors}}
    end
  end

  defp parse_definition(name, %{"schema_version" => @schema_version, "transitions" => transitions}) do
    {:ok, {name, %{transitions: transitions}}}
  end

  defp parse_definition(name, %{"schema_version" => ver}) do
    {:error, {:unsupported_schema_version, name, ver}}
  end

  defp parse_definition(name, _) do
    {:error, {:malformed_definition, name}}
  end

  defp validate_all(definitions) do
    errors =
      Enum.filter(definitions, fn {name, def} ->
        case SchemaValidator.validate(def) do
          :ok -> false
          {:error, _} ->
            Logger.warning("Invalid workflow definition", workflow: name)
            true
        end
      end)

    if errors == [], do: :ok, else: {:error, {:validation_failed, length(errors)}}
  end

  defp build_transition_table(definitions) do
    table =
      Map.new(definitions, fn {name, def} ->
        {:ok, transitions} = compile_transitions(def)
        {name, transitions}
      end)

    {:ok, table}
  end

  defp compile_transitions(%{transitions: raw_transitions}) when is_list(raw_transitions) do
    compiled =
      Enum.map(raw_transitions, fn raw ->
        with {:ok, transition} <- parse_transition(raw) do
          transition
        else
          {:error, reason} ->
            Logger.warning("Skipping invalid transition", reason: inspect(reason))
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, compiled}
  end

  defp compile_transitions(_), do: {:ok, []}

  defp parse_transition(%{"name" => name, "from" => from, "to" => to} = raw) do
    transition = %{
      name: String.to_atom(name),
      from: String.to_atom(from),
      to: String.to_atom(to),
      guard: raw["guard"],
      action: raw["action"]
    }

    {:ok, transition}
  end

  defp parse_transition(_), do: {:error, :missing_transition_fields}
end
```
