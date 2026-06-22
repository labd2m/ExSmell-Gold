defmodule ExSmellGold.Mixfile do
  use Mix.Project

  @project_description """
  ExSmell-Gold is a curated dataset of Elixir code smells designed to support research, benchmarking, and experimentation with automated code smell detection techniques.
  """

  @version "0.0.1"
  @source_url "https://github.com/labd2m/ExSmell-Gold"

  def project do
    [
      app: :ex_smell_gold,
      version: @version,
      elixir: "~> 1.0",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      docs: docs(),
      description: @project_description,
      source_url: @source_url,
      package: package(),
      deps: deps()
    ]
  end

  def application do
    [applications: [:logger]]
  end

  defp deps do
    []
  end

  defp docs() do
    [
      source_ref: "v#{@version}",
      main: "readme",
      extras: [
        "README.md": [title: "README"]
      ]
    ]
  end

  defp package do
    [
      name: :ex_smell_gold,
      maintainers: ["Lucas Vegi", "Mateus Dias"],
      licenses: ["MIT-License"],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end
end
