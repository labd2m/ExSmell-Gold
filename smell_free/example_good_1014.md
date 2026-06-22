```elixir
defmodule Mix.Tasks.Api.GenerateSpec do
  @moduledoc """
  Generates an OpenAPI 3.0 specification from Phoenix router routes and
  optional inline annotations attached to controller modules.

  The output is a JSON file that can be served directly or imported into
  API documentation tools such as Swagger UI or Redoc.

  ## Usage

      mix api.generate_spec
      mix api.generate_spec --output priv/static/openapi.json
      mix api.generate_spec --title "My API" --version "2.0.0"

  """

  use Mix.Task

  @shortdoc "Generates an OpenAPI 3.0 specification from Phoenix routes"

  @default_output "priv/static/openapi.json"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [output: :string, title: :string, version: :string, server: :string]
      )

    Mix.Task.run("app.start")

    output = Keyword.get(opts, :output, @default_output)
    title = Keyword.get(opts, :title, "API Documentation")
    version = Keyword.get(opts, :version, "1.0.0")
    server = Keyword.get(opts, :server, "http://localhost:4000")

    Mix.shell().info("Generating OpenAPI spec...")

    spec = build_spec(title, version, server)
    json = Jason.encode!(spec, pretty: true)

    output |> Path.dirname() |> File.mkdir_p!()
    File.write!(output, json)

    Mix.shell().info("Written to #{output} (#{byte_size(json)} bytes)")
  end

  defp build_spec(title, version, server) do
    routes = collect_routes()

    %{
      "openapi" => "3.0.3",
      "info" => %{"title" => title, "version" => version},
      "servers" => [%{"url" => server}],
      "paths" => build_paths(routes),
      "components" => %{"securitySchemes" => default_security_schemes()}
    }
  end

  defp collect_routes do
    router = Application.get_env(:platform, :router, AppWeb.Router)

    router.__routes__()
    |> Enum.reject(&(&1.path =~ ~r/^\/(_|websocket|live)/))
    |> Enum.group_by(& &1.path)
  end

  defp build_paths(grouped_routes) do
    Map.new(grouped_routes, fn {path, routes} ->
      openapi_path = String.replace(path, ~r/:([a-z_]+)/, "{\\1}")
      operations = Map.new(routes, fn route -> {route.verb, build_operation(route)} end)
      {openapi_path, operations}
    end)
  end

  defp build_operation(route) do
    controller = route.plug
    action = route.plug_opts
    tags = controller_tags(controller)
    description = fetch_action_doc(controller, action)

    op = %{
      "operationId" => "#{controller_name(controller)}_#{action}",
      "tags" => tags,
      "summary" => humanize_action(action),
      "responses" => default_responses()
    }

    if description, do: Map.put(op, "description", description), else: op
  end

  defp controller_tags(controller) do
    controller
    |> Module.split()
    |> List.last()
    |> String.replace("Controller", "")
    |> then(&[&1])
  end

  defp controller_name(controller) do
    controller |> Module.split() |> List.last() |> String.replace("Controller", "") |> Macro.underscore()
  end

  defp humanize_action(action) do
    action |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp fetch_action_doc(controller, action) do
    case Code.fetch_docs(controller) do
      {:docs_v1, _, _, _, _, _, docs} ->
        Enum.find_value(docs, fn
          {{:function, ^action, _}, _, _, %{"en" => doc}, _} -> doc
          _ -> nil
        end)

      _ -> nil
    end
  end

  defp default_responses do
    %{
      "200" => %{"description" => "Success"},
      "401" => %{"description" => "Unauthorized"},
      "422" => %{"description" => "Unprocessable Entity"},
      "500" => %{"description" => "Internal Server Error"}
    }
  end

  defp default_security_schemes do
    %{
      "bearerAuth" => %{
        "type" => "http",
        "scheme" => "bearer",
        "bearerFormat" => "JWT"
      }
    }
  end
end
```
