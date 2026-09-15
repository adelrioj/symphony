defmodule SymphonyElixir.WorkflowTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workflow

  @fixtures Path.expand("../fixtures/lanes", __DIR__)

  test "loading a missing workflow returns its path and filesystem reason" do
    path = Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive, :monotonic])}.md")
    assert {:error, {:missing_workflow_file, ^path, :enoent}} = Workflow.load(path)
  end

  test "split and render preserve the checked-in workflow bytes" do
    for file <- ~w(client-template.md example.md) do
      content = File.read!(Path.join(@fixtures, file))
      %{front_matter: front_matter, prompt: prompt} = Workflow.split(content)

      assert Workflow.render(front_matter, prompt) == content
      assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}}} = Workflow.parse_parts(front_matter, prompt)
    end
  end

  test "raw sections retain blank lines, YAML comments, and a prompt without a final newline" do
    content = "---\n\n# Keep this comment\na: 1\n\n---\n\nP\n---\nlast"

    assert %{front_matter: "\n# Keep this comment\na: 1\n", prompt: "\nP\n---\nlast"} = Workflow.split(content)
    %{front_matter: front_matter, prompt: prompt} = Workflow.split(content)
    assert Workflow.render(front_matter, prompt) == content
    assert {:ok, %{config: %{"a" => 1}, prompt: "P\n---\nlast"}} = Workflow.parse(content)
  end

  test "prompt-only files retain their raw bytes" do
    content = "\nJust a prompt\r\n---\r\n"
    assert Workflow.split(content) == %{front_matter: "", prompt: content}
    assert Workflow.render("", content) == content
    assert {:ok, %{config: %{}, prompt: "Just a prompt\n---"}} = Workflow.parse(content)
  end

  test "CRLF sections stay raw while parsed prompts retain LF normalization" do
    content = "---\r\na: 1\r\nb: 2\r\n---\r\nP\r\nQ"

    assert %{front_matter: "a: 1\r\nb: 2", prompt: "P\r\nQ"} = Workflow.split(content)
    assert {:ok, %{config: %{"a" => 1, "b" => 2}, prompt: "P\nQ"}} = Workflow.parse(content)
  end

  test "parsing retains support for Unicode line separators in YAML and prompts" do
    assert {:ok, %{config: %{"a" => 1, "b" => 2}, prompt: "P\nQ"}} =
             Workflow.parse("---\na: 1\fb: 2\n---\nP\u2028Q")
  end

  test "empty front matter and a closing delimiter at EOF still parse" do
    assert %{front_matter: "", prompt: "P"} = Workflow.split("---\n---\nP")
    assert {:ok, %{config: %{}, prompt: "P"}} = Workflow.parse("---\n---\nP")
    assert %{front_matter: "a: 1", prompt: ""} = Workflow.split("---\na: 1\n---")
    assert {:ok, %{config: %{"a" => 1}, prompt: ""}} = Workflow.parse("---\na: 1\n---")
  end

  test "an unterminated front matter block retains existing YAML parsing behavior" do
    assert {:ok, %{config: %{"a" => 1}, prompt: ""}} = Workflow.parse("---\na: 1\n")
    assert {:ok, %{config: %{}, prompt: ""}} = Workflow.parse("---")
  end

  test "render treats leading blank YAML lines as content rather than envelope metadata" do
    assert Workflow.render("\na: 1", "P") == "---\n\na: 1\n---\nP"
  end

  test "parse_parts decodes YAML, trims prompts, and rejects malformed or non-map YAML" do
    assert {:ok, %{config: %{"polling" => %{"interval_ms" => 5}}, prompt: "Hi", prompt_template: "Hi"}} =
             Workflow.parse_parts("polling:\n  interval_ms: 5", "\nHi\n")

    assert {:ok, %{config: %{}, prompt: "Hi"}} = Workflow.parse_parts("", "Hi")
    assert {:ok, %{config: %{}, prompt: "Hi"}} = Workflow.parse_parts(" \r\n", "Hi")
    assert {:error, :workflow_front_matter_not_a_map} = Workflow.parse_parts("- a\n- b", "")
    assert {:error, {:workflow_parse_error, _}} = Workflow.parse_parts("tracker: [", "")
  end

  # The snapshot is shipped to the worker and read there by the tracker MCP server.
  # `worker.environment` points at controller-local paths — `provider.kubeconfig` above
  # all — which a guest cannot resolve, so the server exits and the agent is left with
  # no approval channel and hangs until its attempt is abandoned.
  test "a snapshot bound for a worker carries no controller-only environment" do
    content =
      Workflow.render(
        "tracker:\n  kind: memory\nworker:\n  environment:\n    kind: kubernetes\n    provider:\n      kubeconfig: /run/candidate/provider.kubeconfig\n",
        "Do the thing."
      )

    sanitized = Workflow.for_worker(content)

    assert {:ok, %{config: config, prompt: "Do the thing."}} = Workflow.parse(sanitized)
    refute match?(%{"worker" => %{"environment" => _}}, config)
    assert config["tracker"] == %{"kind" => "memory"}
  end

  test "for_worker keeps worker settings that are not the environment, and is a no-op otherwise" do
    content = Workflow.render("worker:\n  shell: bash\n  environment:\n    kind: kubernetes\n", "P")
    assert {:ok, %{config: %{"worker" => worker}}} = Workflow.parse(Workflow.for_worker(content))
    assert worker == %{"shell" => "bash"}

    plain = Workflow.render("tracker:\n  kind: memory\n", "P")
    assert Workflow.for_worker(plain) == plain
  end
end
