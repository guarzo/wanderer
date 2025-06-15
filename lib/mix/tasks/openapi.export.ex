defmodule Mix.Tasks.Openapi.Export do
  @moduledoc """
  Export OpenAPI specification to a JSON file for version comparison and documentation.

  ## Usage

      mix openapi.export [--output path/to/spec.json]

  ## Options

    * `--output` - Output file path (defaults to `priv/static/openapi.json`)
    * `--format` - Output format: json or yaml (defaults to json)

  ## Examples

      # Export to default location
      mix openapi.export

      # Export to custom location
      mix openapi.export --output docs/api/v1/spec.json

      # Export as YAML
      mix openapi.export --format yaml
  """

  use Mix.Task

  @shortdoc "Export OpenAPI specification to file"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [output: :string, format: :string],
        aliases: [o: :output, f: :format]
      )

    output_path = opts[:output] || "priv/static/openapi.json"
    format = String.to_atom(opts[:format] || "json")

    Mix.Task.run("compile")
    Mix.Task.run("app.start")

    # Get the OpenAPI spec
    spec = WandererAppWeb.ApiSpec.spec()

    # Ensure output directory exists
    output_path
    |> Path.dirname()
    |> File.mkdir_p!()

    # Write the spec
    case format do
      :json ->
        json =
          spec
          |> OpenApiSpex.OpenApi.to_map()
          |> Jason.encode!(pretty: true)

        File.write!(output_path, json)
        Mix.shell().info("OpenAPI spec exported to #{output_path}")

      :yaml ->
        # Note: YAML export would require additional dependency like yamerl or fast_yaml
        Mix.raise("YAML format not yet implemented. Please use JSON format.")

      _ ->
        Mix.raise("Unknown format: #{format}. Supported formats: json")
    end
  end
end
