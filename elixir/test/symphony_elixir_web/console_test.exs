defmodule SymphonyElixirWeb.ConsoleTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LaneStore.Entry
  alias SymphonyElixir.Runs.Run
  alias SymphonyElixirWeb.Console

  @settings %{
    tracker: %{active_states: ["Todo", "In Progress"], terminal_states: ["Done"]},
    agent: %{
      max_concurrent_agents: 3,
      max_turns: 20,
      backend: "codex",
      blocked_state: "Blocked"
    }
  }

  test "flattens live entries and finished history into lane-scoped tickets" do
    runs = [
      run("i5", "A-5", "done"),
      run("i5", "A-5", "failed"),
      run("i1", "A-1", "done"),
      run("i6", "A-6", "running")
    ]

    tickets =
      Console.tickets([
        %{entry: entry("main"), payload: payload(), runs: runs}
      ])

    assert Enum.map(tickets, &{&1.identifier, &1.status}) == [
             {"A-1", "running"},
             {"A-2", "blocked"},
             {"A-3", "retrying"},
             {"A-4", "queued"},
             {"A-5", "done"}
           ]

    assert %{
             key: "main:i1",
             lane: "main",
             labels: ["api"],
             turn_count: 4,
             url: "https://linear.app/a/A-1"
           } = hd(tickets)

    assert %{key: "main:i4", blocked_by: ["A-1"], url: nil} =
             Enum.at(tickets, 3)

    assert %{
             title: "Old A-5",
             tokens: %{total_tokens: 6},
             started_at: "2026-09-27T09:00:00Z"
           } = List.last(tickets)
  end

  test "environment-only credential recovery stays visible in attention and other tracker states" do
    environment = recovery_environment()

    tickets =
      Console.tickets([
        %{
          entry: entry("main"),
          payload: %{running: [], blocked: [], retrying: [], queued: [], environments: [environment]},
          runs: []
        }
      ])

    assert [
             %{
               key: "main:bon-143",
               identifier: "BON-143",
               source: :environment,
               status: "blocked",
               history: false,
               title: nil,
               tracker_state: nil,
               url: nil,
               attempt: nil,
               error: "checkpoint_failed",
               environment: ^environment
             } = ticket
           ] = tickets

    assert %{label: "Needs attention", tickets: [^ticket]} =
             Enum.find(Console.groups(tickets, :status, [entry("main")]), &(&1.key == "blocked"))

    assert [%{label: "Other states", tickets: [^ticket]}] =
             Console.groups(tickets, :tracker, [entry("main")])

    assert %{agents: [], idle: 3, max: 3} = Console.strip(entry("main"), tickets)
  end

  test "credential recovery is visible with no unresolved marker and an unknown phase" do
    environment = %{recovery_environment() | phase: :unknown, unresolved: nil}

    assert [%{status: "blocked", source: :environment, environment: ^environment}] =
             Console.tickets([
               %{entry: entry("main"), payload: %{environments: [environment]}, runs: []}
             ])
  end

  test "unresolved environments need attention without credential recovery" do
    environment = %{
      recovery_environment()
      | credential: nil,
        unresolved: %{operation: :stop, category: :transient, code: :provider_unavailable}
    }

    assert [%{status: "blocked", error: "provider_unavailable", environment: ^environment}] =
             Console.tickets([
               %{entry: entry("main"), payload: %{environments: [environment]}, runs: []}
             ])
  end

  test "runtime tickets remain authoritative and retain matching environment details" do
    environment = %{recovery_environment() | issue_id: "i1", issue_identifier: "A-1"}

    tickets =
      Console.tickets([
        %{
          entry: entry("main"),
          payload: Map.put(payload(), :environments, [environment]),
          runs: [run("i1", "A-1", "done")]
        }
      ])

    assert [
             %{
               source: :runtime,
               status: "running",
               title: "Run",
               tracker_state: "In Progress",
               url: "https://linear.app/a/A-1",
               environment: ^environment
             }
           ] = Enum.filter(tickets, &(&1.issue_id == "i1"))

    assert %{agents: [%{issue_id: "i1"}, %{issue_id: "i2"}], idle: 2} =
             Console.strip(entry("main"), tickets)
  end

  test "environment recovery suppresses older history without borrowing tracker metadata" do
    tickets =
      Console.tickets([
        %{
          entry: entry("main"),
          payload: %{environments: [recovery_environment()]},
          runs: [run("bon-143", "BON-143", "done"), run("bon-143", "BON-143", "failed")]
        }
      ])

    assert [%{source: :environment, title: nil, tracker_state: nil, url: nil, attempt: nil}] = tickets
    assert %{tickets: []} = Enum.find(Console.groups(tickets, :status, []), &(&1.key == "finished"))
  end

  test "healthy retained stopped environments do not become blocked tickets" do
    environment = %{recovery_environment() | phase: :stopped, credential: nil, unresolved: nil, occupies_slot: false}

    assert [] =
             Console.tickets([
               %{entry: entry("main"), payload: %{environments: [environment]}, runs: []}
             ])

    assert [%{source: :history, status: "done", environment: nil}] =
             Console.tickets([
               %{
                 entry: entry("main"),
                 payload: %{environments: [environment]},
                 runs: [run("bon-143", "BON-143", "done")]
               }
             ])
  end

  test "keys stay unique across lanes, and unavailable lanes contribute only history" do
    unavailable = %{error: %{code: "snapshot_unavailable"}}

    tickets =
      Console.tickets([
        %{entry: entry("main"), payload: payload(), runs: []},
        %{
          entry: entry("other", settings: nil),
          payload: unavailable,
          runs: [run("i1", "A-1", "done")]
        }
      ])

    keys = Enum.map(tickets, & &1.key)
    assert "main:i1" in keys and "other:i1" in keys
    assert length(keys) == length(Enum.uniq(keys))
  end

  test "run-status groups keep a fixed order, keep empty groups, and put all history under finished" do
    tickets =
      Console.tickets([
        %{
          entry: entry("main"),
          payload: payload(),
          runs: [run("i5", "A-5", "turns_exhausted"), run("i7", "A-7", "blocked")]
        }
      ])

    assert Enum.map(
             Console.groups(tickets, :status, [entry("main")]),
             &{&1.key, length(&1.tickets)}
           ) == [
             {"running", 1},
             {"blocked", 1},
             {"retrying", 1},
             {"queued", 1},
             {"finished", 2}
           ]

    assert %{tickets: [%{identifier: "A-2", history: false}]} =
             Enum.find(Console.groups(tickets, :status, []), &(&1.key == "blocked"))

    assert Enum.map(Console.groups([], :status, []), &length(&1.tickets)) ==
             [0, 0, 0, 0, 0]
  end

  test "tracker-state groups follow lane config, merge spellings, and keep history apart" do
    github =
      entry("mobile",
        settings: %{
          tracker: %{active_states: ["todo"], terminal_states: nil},
          agent: %{
            max_concurrent_agents: 1,
            max_turns: 30,
            backend: "claude",
            blocked_state: "Blocked"
          }
        }
      )

    tickets =
      Console.tickets([
        %{
          entry: entry("main"),
          payload: payload(),
          runs: [run("i5", "A-5", "done"), run("i7", "A-7", "blocked")]
        },
        %{
          entry: github,
          payload: %{
            queued: [
              %{
                issue_id: "g1",
                issue_identifier: "#1",
                state: "triage"
              }
            ]
          },
          runs: []
        }
      ])

    groups =
      Console.groups(tickets, :tracker, [
        entry("main"),
        github,
        entry("broken", settings: nil)
      ])

    assert Enum.map(
             groups,
             &{&1.label, &1.category, Enum.map(&1.tickets, fn t -> t.identifier end)}
           ) == [
             {"Todo", "active", ["A-3", "A-4"]},
             {"In Progress", "active", ["A-1"]},
             {"Blocked", "blocked", ["A-2"]},
             {"Other states", nil, ["#1"]},
             {"Finished runs", nil, ["A-5", "A-7"]}
           ]
  end

  test "strip shows live running and blocked agents and counts idle slots from running only" do
    tickets =
      Console.tickets([
        %{entry: entry("main"), payload: payload(), runs: [run("i7", "A-7", "blocked")]}
      ])

    assert %{agents: [%{identifier: "A-1"}, %{identifier: "A-2"}], idle: 2, max: 3} =
             Console.strip(entry("main"), tickets)

    assert %{agents: [], idle: 0, max: 0} =
             Console.strip(entry("off", enabled: false), tickets)

    assert %{idle: 0, max: 0} =
             Console.strip(entry("broken", settings: nil), [])

    assert Console.agent_setting(entry("main"), :backend, "codex") == "codex"

    assert Console.agent_setting(
             entry("broken", settings: nil),
             :backend,
             "codex"
           ) == "codex"
  end

  test "formats durations and ignores missing or unparsable times" do
    at = ~U[2026-09-27 10:00:00Z]
    assert Console.duration(at, DateTime.add(at, 42)) == "42s"
    assert Console.duration(DateTime.to_iso8601(at), DateTime.add(at, 724)) == "12m 04s"
    assert Console.duration(at, DateTime.add(at, 3 * 3600 + 5 * 60)) == "3h 05m"
    assert Console.duration(at, DateTime.add(at, -10)) == "0s"
    assert Console.duration(nil, at) == nil
    assert Console.duration("not a time", at) == nil
  end

  test "formats token counts the way people read them" do
    assert Console.format_tokens(nil) == "0"
    assert Console.format_tokens(412) == "412"
    assert Console.format_tokens(2_600) == "2.6k"
    assert Console.format_tokens(999_949) == "999.9k"
    assert Console.format_tokens(999_950) == "1.0m"
    assert Console.format_tokens(4_012_000) == "4.0m"
  end

  test "describes stored event payloads and keeps only web tracker links" do
    assert Console.describe_event(%{"message" => "hello"}) == "hello"

    assert Console.describe_event(%{
             "total_tokens" => 7,
             "input_tokens" => 3,
             "output_tokens" => 4
           }) == "in 3 / out 4 / cached 0 / total 7"

    assert Console.describe_event(%{"event" => "turn_started"}) == "turn_started"
    assert Console.describe_event(%{"other" => 1}) == ~s({"other":1})

    assert Console.external_url(" https://linear.app/a/A-1 ") ==
             "https://linear.app/a/A-1"

    assert Console.external_url("javascript:alert(1)") == nil
    assert Console.external_url("https://") == nil
    assert Console.external_url(nil) == nil
  end

  test "handles non-binary tracker_state in grouping" do
    # Create a ticket with nil tracker_state to test same_state? handling
    tickets = [
      %{
        key: "test:1",
        lane: "test",
        issue_id: "i1",
        identifier: "T-1",
        title: nil,
        tracker_state: nil,
        status: "blocked",
        history: false,
        labels: [],
        url: nil,
        blocked_by: [],
        attempt: nil,
        turn_count: nil,
        last_message: nil,
        error: nil,
        due_at: nil,
        started_at: nil,
        tokens: nil
      }
    ]

    # Grouping by tracker state should not crash and put nil state in "other"
    groups = Console.groups(tickets, :tracker, [entry("test")])
    other_group = Enum.find(groups, &(&1.key == "other"))
    assert other_group != nil
    assert length(other_group.tickets) == 1
  end

  defp recovery_environment do
    %{
      environment_id: "env-bon-143",
      provider: "workstations",
      issue_id: "bon-143",
      issue_identifier: "BON-143",
      phase: :stopping,
      desired: :stopped,
      occupies_slot: true,
      workspace_path: "/fixture/BON-143",
      provider_resource_id: "fixture-workstation",
      terminal_observed_at: nil,
      credential: %{stage: "recovery_required", reason: "checkpoint_failed"},
      unresolved: nil
    }
  end

  defp entry(slug, opts \\ []) do
    %Entry{
      lane_id: slug,
      slug: slug,
      name: String.capitalize(slug),
      enabled: Keyword.get(opts, :enabled, true),
      settings: Keyword.get(opts, :settings, @settings)
    }
  end

  defp payload do
    %{
      running: [
        %{
          issue_id: "i1",
          issue_identifier: "A-1",
          issue_url: "https://linear.app/a/A-1",
          title: "Run",
          state: "In Progress",
          labels: ["api"],
          turn_count: 4,
          last_message: "working",
          tokens: %{input_tokens: 10, output_tokens: 2, total_tokens: 12},
          started_at: "2026-09-27T10:00:00Z"
        }
      ],
      blocked: [
        %{
          issue_id: "i2",
          issue_identifier: "A-2",
          title: nil,
          state: "Blocked",
          error: "approval_required"
        }
      ],
      retrying: [
        %{
          issue_id: "i3",
          issue_identifier: "A-3",
          title: "Again",
          state: "todo",
          attempt: 2,
          due_at: "2026-09-27T10:05:00Z",
          error: "turn_failed"
        }
      ],
      queued: [
        %{
          issue_id: "i4",
          issue_identifier: "A-4",
          title: "Next",
          state: "Todo",
          labels: [],
          issue_url: "file:///etc/passwd",
          blocked_by: ["A-1"]
        }
      ]
    }
  end

  defp run(issue_id, identifier, status) do
    %Run{
      issue_id: issue_id,
      issue_identifier: identifier,
      issue_title: "Old " <> identifier,
      issue_state: "Todo",
      status: status,
      attempt_id: "#{identifier}-#{status}",
      attempt: 1,
      turns: 3,
      input_tokens: 5,
      output_tokens: 1,
      started_at: ~U[2026-09-27 09:00:00Z]
    }
  end
end
