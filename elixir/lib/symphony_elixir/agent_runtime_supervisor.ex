defmodule SymphonyElixir.AgentRuntimeSupervisor do
  @moduledoc """
  Supervises the scheduler authority together with its agent tasks.
  """

  use Supervisor

  alias SymphonyElixir.LaneContext

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts = Keyword.put_new_lazy(opts, :lane_id, &LaneContext.current!/0)
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts), do: Supervisor.init(child_specs(opts), strategy: :one_for_all)

  @doc "The lane runtime's children, exposed so what a lane supervises can be asserted directly."
  @spec child_specs(keyword()) :: [Supervisor.child_spec()]
  def child_specs(opts) do
    task_supervisor_name =
      Keyword.get(opts, :task_supervisor_name, SymphonyElixir.TaskSupervisor)

    orchestrator_name = Keyword.get(opts, :orchestrator_name, SymphonyElixir.Orchestrator)
    lane_id = Keyword.fetch!(opts, :lane_id)

    [
      Supervisor.child_spec(
        {Task.Supervisor, name: task_supervisor_name},
        id: task_supervisor_name
      ),
      Supervisor.child_spec(
        {SymphonyElixir.Orchestrator, Keyword.merge(Keyword.take(opts, [:environment_operation_fun, :runner_fun]), lane_id: lane_id, name: orchestrator_name, task_supervisor: task_supervisor_name)},
        id: orchestrator_name
      ),
      # Resolves its own environment each pass and idles unless this lane runs on Kubernetes, so
      # it costs a sleeping process on lanes that do not.
      Supervisor.child_spec(
        {SymphonyElixir.ExecutionEnvironment.Kubernetes.DeclarationReconciler, [lane_id: lane_id, name: nil]},
        id: SymphonyElixir.ExecutionEnvironment.Kubernetes.DeclarationReconciler
      )
    ]
  end
end
