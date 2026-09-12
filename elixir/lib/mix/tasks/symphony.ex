defmodule Mix.Tasks.Symphony do
  @shortdoc "Runs the Symphony CLI"
  @moduledoc """
  Runs the Symphony CLI with the project's compiled dependencies available,
  including SQLite's native library.

  Loads application configuration without starting the daemon. The CLI owns
  argument validation and runtime startup.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  defdelegate run(args), to: SymphonyElixir.CLI, as: :main
end
