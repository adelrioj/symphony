# Entry point for the Kubernetes candidate runner (docker/Dockerfile target `candidate`).
#
# This was hand-written into the runner pod for every qualification run until 2026-09-18,
# which is one more thing that could silently differ between the image and the run. It is
# committed so it cannot.
#
# Requires MIX_ENV=test: SymphonyElixir.ExecutionEnvironment.Kubernetes.Candidate is wrapped
# in `if Mix.env() == :test`, and the runner is a plain .exs required at runtime.
database = System.fetch_env!("SYMPHONY_CANDIDATE_DB")
false = File.exists?(database)
Application.put_env(:symphony_elixir, :data_root, Path.dirname(database))
Application.put_env(:symphony_elixir, SymphonyElixir.Repo, database: database)
{:ok, _} = Application.ensure_all_started(:symphony_elixir)
Code.require_file("test/support/kubernetes_candidate_runner.exs")

case SymphonyElixir.KubernetesCandidateRunner.run_file(System.fetch_env!("SYMPHONY_KUBERNETES_CANDIDATE_INPUT")) do
  {:ok, output} -> IO.puts(output)
  {:error, reason} -> IO.inspect(reason, label: "candidate runner failed"); System.halt(1)
end
