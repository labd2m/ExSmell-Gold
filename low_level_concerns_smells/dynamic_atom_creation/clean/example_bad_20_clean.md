```elixir
defmodule MyApp.CLI.TaskRunner do
  @moduledoc """
  Entry point for the MyApp command-line interface.
  Parses command-line arguments and dispatches to the appropriate
  Mix task or standalone runner module.
  """

  require Logger

  alias MyApp.CLI.{OutputFormatter, HelpPrinter}

  @registered_commands %{
    migrate: MyApp.Tasks.Migrate,
    seed: MyApp.Tasks.Seed,
    export: MyApp.Tasks.Export,
    import: MyApp.Tasks.Import,
    report: MyApp.Tasks.Report,
    backfill: MyApp.Tasks.Backfill,
    cleanup: MyApp.Tasks.Cleanup,
    health_check: MyApp.Tasks.HealthCheck
  }

  @global_flags ~w(--verbose --dry-run --json --no-color --help)

  @doc """
  Main entrypoint invoked by `main/1` in the escript.
  """
  @spec run([String.t()]) :: :ok | {:error, term()}
  def run(argv) do
    case parse_args(argv) do
      {:help, _} ->
        HelpPrinter.print_usage(@registered_commands)
        :ok

      {:ok, command, task_opts, global_opts} ->
        configure_logging(global_opts)
        Logger.info("Running CLI command", command: command)

        case dispatch(command, task_opts, global_opts) do
          :ok ->
            :ok

          {:ok, result} ->
            if Keyword.get(global_opts, :json) do
              IO.puts(Jason.encode!(result, pretty: true))
            else
              OutputFormatter.print(result)
            end

            :ok

          {:error, reason} ->
            Logger.error("Command failed", command: command, reason: inspect(reason))
            {:error, reason}
        end

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{reason}")
        HelpPrinter.print_usage(@registered_commands)
        {:error, reason}
    end
  end

  defp parse_args(["--help" | _]), do: {:help, []}
  defp parse_args(["-h" | _]), do: {:help, []}

  defp parse_args([command_str | rest]) when is_binary(command_str) do
    {global_flags, task_args} = Enum.split_with(rest, &(&1 in @global_flags))

    global_opts = [
      verbose: "--verbose" in global_flags,
      dry_run: "--dry-run" in global_flags,
      json: "--json" in global_flags,
      no_color: "--no-color" in global_flags
    ]

    command_atom = String.to_atom(command_str)
    task_opts = parse_task_opts(task_args)

    {:ok, command_atom, task_opts, global_opts}
  end

  defp parse_args([]), do: {:help, []}

  defp parse_args(_), do: {:error, "Unexpected argument format"}

  defp dispatch(command, task_opts, global_opts) do
    case Map.fetch(@registered_commands, command) do
      {:ok, module} ->
        module.run(task_opts, global_opts)

      :error ->
        available = @registered_commands |> Map.keys() |> Enum.map_join(", ", &Atom.to_string/1)
        {:error, "Unknown command '#{command}'. Available: #{available}"}
    end
  end

  defp parse_task_opts(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      ["--" <> key, value] when not String.starts_with?(value, "--") ->
        [{String.to_existing_atom(String.replace(key, "-", "_")), value}]

      _ ->
        []
    end)
  rescue
    ArgumentError -> []
  end

  defp configure_logging(opts) do
    if Keyword.get(opts, :verbose) do
      Logger.configure(level: :debug)
    else
      Logger.configure(level: :info)
    end
  end
end
```
