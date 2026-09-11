ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)

# Individual tests own their runtime and workers; an application-wide scheduler must
# not dispatch against another test's temporary workflow or process environment.
:ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.AgentRuntimeSupervisor)
