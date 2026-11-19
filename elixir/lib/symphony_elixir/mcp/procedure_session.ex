defmodule SymphonyElixir.MCP.ProcedureSession do
  @moduledoc false

  alias SymphonyElixir.Agent.Result
  alias SymphonyElixir.{Config, Lanes, Tracker}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Tracker.Issue

  @primary ~w(qa bug deliver)
  @secondary "error-reporting"
  @sections @primary ++ [@secondary]
  @bug_labels ~w(bug bug-symphony)
  @deliver_labels ~w(feature improvement feat-symphony chore)
  @env "SYMPHONY_CLAUDE_PROCEDURE_CONTEXT"
  @error_reporting_request ~r/\{\s*"section"\s*:\s*"error-reporting"\s*\}/
  @tool %{
    "name" => "read_procedure",
    "description" => "Read the selected procedure from this run's lane version after checking the live issue.",
    "inputSchema" => %{
      "type" => "object",
      "properties" => %{"section" => %{"type" => "string", "enum" => @sections}},
      "required" => ["section"],
      "additionalProperties" => false
    }
  }

  @type t :: %{
          path: Path.t(),
          issue_id: String.t(),
          slug: String.t(),
          procedures: map()
        }

  @type blocker :: String.t() | {:missing_procedure, String.t()}

  @spec managed_lane?(term()) :: boolean()
  def managed_lane?(slug), do: Lanes.procedure_fields(slug) != []

  @spec tool_spec() :: map()
  def tool_spec, do: @tool

  @spec env_name() :: String.t()
  def env_name, do: @env

  @spec incomplete?(map() | nil) :: boolean()
  def incomplete?(procedures) when is_map(procedures),
    do: Enum.any?(@primary, &(not present_text?(procedures[&1])))

  def incomplete?(_procedures), do: true

  @spec outcome_path(Path.t()) :: Path.t()
  def outcome_path(path), do: path <> ".outcome"

  @spec encode(String.t(), String.t(), map() | nil) :: {:ok, binary()} | {:error, atom()}
  def encode(issue_id, slug, procedures) when is_binary(issue_id) and issue_id != "" do
    payload = %{issue_id: issue_id, slug: slug, procedures: procedures || %{}}

    case Jason.encode(payload) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, :procedure_context_encode}
    end
  end

  def encode(_issue_id, _slug, _procedures), do: {:error, :procedure_issue_id_required}

  @spec current() :: {:ok, t()} | {:error, atom()}
  def current do
    case System.get_env(@env) do
      nil -> {:error, :procedure_context_unavailable}
      path -> bound_session(path)
    end
  end

  defp bound_session(path) do
    case Process.get({__MODULE__, :bound_session}) do
      %{path: ^path} = session ->
        {:ok, session}

      _ ->
        with {:ok, session} <- load(path) do
          Process.put({__MODULE__, :bound_session}, session)
          {:ok, session}
        end
    end
  end

  @spec load(Path.t()) :: {:ok, t()} | {:error, atom()}
  def load(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"issue_id" => id, "slug" => slug, "procedures" => procedures}} <- Jason.decode(contents),
         true <- is_binary(id) and id != "" and managed_lane?(slug) and is_map(procedures) do
      {:ok, %{path: path, issue_id: id, slug: slug, procedures: procedures}}
    else
      _ -> {:error, :procedure_context_invalid}
    end
  end

  # Common is never started for a legacy managed bundle. For partially damaged bundles only,
  # check before launch as well as at the tool: a missing unselected section does not block.
  @spec preflight(t()) :: :ok | {:blocked, blocker()}
  def preflight(%{procedures: procedures}) when map_size(procedures) == 0,
    do: {:blocked, "The managed lane's procedure bundle is missing or blank."}

  def preflight(%{procedures: procedures, issue_id: id}) do
    case live_route(id) do
      {:selected, section} ->
        if present_text?(procedures[section]), do: :ok, else: {:blocked, {:missing_procedure, section}}

      _ ->
        :ok
    end
  end

  @spec check_unread(t()) :: :ok | {:blocked, blocker()} | {:error, atom()}
  def check_unread(%{issue_id: id, procedures: procedures}) do
    case live_route(id) do
      :no_route ->
        :ok

      {:selected, section} ->
        if present_text?(procedures[section]),
          do: {:error, :procedure_not_read},
          else: {:blocked, {:missing_procedure, section}}

      :conflict ->
        {:error, :procedure_route_conflict}

      :unverified ->
        {:error, :procedure_live_issue_unverified}
    end
  end

  @spec read(t(), term()) :: {:ok, String.t()} | {:error, String.t()}
  def read(session, %{"section" => section} = args) when section in @sections and map_size(args) == 1 do
    with {:ok, previous} <- File.read(outcome_path(session.path)),
         :ok <- not_blocked(previous),
         :ok <- authorize(live_route(session.issue_id), section, session, previous) do
      return_text(session, section)
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "The procedure outcome could not be recorded. Stop without using procedure text."}
    end
  end

  def read(_session, _args), do: {:error, "Provide only a valid procedure section."}

  defp not_blocked("blocked:" <> _), do: {:error, "This run is blocked on its missing procedure."}
  defp not_blocked(_), do: :ok

  defp authorize({:selected, section}, section, _session, _previous), do: :ok

  defp authorize(
         {:selected, section},
         @secondary,
         %{slug: "bonbons-delivery", procedures: procedures},
         "read:" <> previous
       )
       when section in ["bug", "deliver"] and section == previous do
    if requests_error_reporting?(procedures[section]),
      do: :ok,
      else: {:error, "The selected procedure does not request Error Reporting."}
  end

  defp authorize(:unverified, _section, _slug, _previous),
    do: {:error, "The live state and labels of this run's issue could not be verified."}

  defp authorize(_route, _section, _slug, _previous),
    do: {:error, "This section is not available for the live route of this run's issue."}

  defp requests_error_reporting?(text) when is_binary(text) do
    String.contains?(text, "mcp__symphony__read_procedure") and Regex.match?(@error_reporting_request, text)
  end

  defp requests_error_reporting?(_text), do: false

  defp return_text(%{path: path, procedures: procedures}, section) do
    text = procedures[section]

    cond do
      not present_text?(text) ->
        case File.write(outcome_path(path), "blocked:" <> section) do
          :ok ->
            {:error, missing_text(section) <> " Stop without writing to Linear; Symphony will recheck the live route."}

          {:error, _reason} ->
            {:error, "Unable to record the missing procedure. Stop without using procedure text."}
        end

      section == @secondary ->
        {:ok, text}

      true ->
        case File.write(outcome_path(path), "read:" <> section) do
          :ok -> {:ok, text}
          {:error, _reason} -> {:error, "Unable to record the procedure read. Stop without using procedure text."}
        end
    end
  end

  defp live_route(id) do
    if Config.settings!().tracker.kind == "linear" do
      case Client.fetch_issue_route(id) do
        {:ok, {state, labels}} -> select(state, labels)
        {:ok, nil} -> :no_route
        {:error, _reason} -> :unverified
      end
    else
      tracker_route(id)
    end
  end

  defp tracker_route(id) do
    case Tracker.fetch_issues_by_ids([id]) do
      {:ok, [%Issue{id: ^id, state: state, labels: labels}]} when is_binary(state) and is_list(labels) ->
        select(state, labels)

      {:ok, []} ->
        :no_route

      _ ->
        :unverified
    end
  end

  @spec permit_blocked_write(String.t(), String.t() | nil, map() | nil) :: :ok | :skip | {:error, atom()}
  def permit_blocked_write(id, missing_procedure, procedures) do
    case live_route(id) do
      :no_route ->
        :skip

      :unverified ->
        {:error, :procedure_live_issue_unverified}

      _route when is_nil(missing_procedure) ->
        :ok

      {:selected, ^missing_procedure} ->
        :ok

      {:selected, section} when missing_procedure == @secondary and section in ["bug", "deliver"] ->
        if requests_error_reporting?(procedures[section]), do: :ok, else: :skip

      _route ->
        :skip
    end
  end

  defp select(state, labels) do
    labels = MapSet.new(labels, &String.downcase/1)

    cond do
      "human" in labels or "groomed" not in labels -> :no_route
      state == "In Review" -> {:selected, "qa"}
      state in ["Todo", "In Progress"] -> select_delivery(labels)
      true -> :no_route
    end
  end

  defp select_delivery(labels) do
    bug? = Enum.any?(@bug_labels, &MapSet.member?(labels, &1))

    cond do
      bug? and Enum.any?(@deliver_labels, &MapSet.member?(labels, &1)) -> :conflict
      bug? -> {:selected, "bug"}
      true -> {:selected, "deliver"}
    end
  end

  defp present_text?(text), do: is_binary(text) and String.trim(text) != ""

  @spec missing_text(String.t()) :: String.t()
  def missing_text(section), do: "The selected #{section} procedure is missing or blank in this run's lane version."

  @spec blocked_result(blocker(), {:ok, Result.t()} | {:error, term()} | nil) :: {:ok, Result.t()}
  def blocked_result(blocker, result \\ nil)

  def blocked_result({:missing_procedure, section}, result) do
    {:ok, blocked} = blocked_result(missing_text(section), result)
    {:ok, %{blocked | missing_procedure: section}}
  end

  def blocked_result(detail, {:ok, %Result{} = result}), do: {:ok, %{result | status: :blocked, blocked_action: detail}}
  def blocked_result(detail, _result), do: {:ok, Result.new(status: :blocked, blocked_action: detail)}
end
