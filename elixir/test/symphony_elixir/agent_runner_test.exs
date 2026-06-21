defmodule SymphonyElixir.AgentRunnerStubBackend do
  @behaviour SymphonyElixir.Agent

  alias SymphonyElixir.Agent.Result

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{turns: 0}}

  @impl true
  def run_turn(_session, _prompt, _issue, opts) do
    if pid = opts[:test_pid], do: send(pid, :stub_turn_ran)
    {:ok, Result.new(status: :done, session_id: "stub-1")}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

  test "run/3 drives the injected backend module" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-backend-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    issue = %Issue{
      id: "issue-stub-backend",
      identifier: "STUB-1",
      title: "Run a stub backend",
      description: "The injected backend should receive the turn.",
      state: "Done",
      url: "https://example.org/issues/STUB-1",
      labels: []
    }

    assert :ok =
             AgentRunner.run(
               issue,
               nil,
               backend_module: SymphonyElixir.AgentRunnerStubBackend,
               worker_host: nil,
               issue_state_fetcher: fn _ids -> {:ok, [issue]} end,
               test_pid: self()
             )

    assert_received :stub_turn_ran
  end
end
