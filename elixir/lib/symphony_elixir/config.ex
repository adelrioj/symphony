defmodule SymphonyElixir.Config do
  @moduledoc """
  Workflow settings and installation-level runtime configuration.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ExecutionEnvironment
  alias SymphonyElixir.ExecutionEnvironment.Config, as: EnvironmentConfig
  alias SymphonyElixir.{LaneContext, LaneStore}
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on an issue from the configured tracker.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  {% assign attachment_count = issue.attachments | size %}
  {% if attachment_count > 0 %}
  Attachments (files attached to this ticket; contents are not inlined here):
  {% for attachment in issue.attachments %}
  - {{ attachment.title }} — {{ attachment.url }}
  {% endfor %}
  Read an attachment's contents with the `linear_fetch_attachment` tool, passing its `url`. A `<IDENT>-design.md` attachment is the authoritative design spec.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @doc "Directory holding `symphony.sqlite3` and `log/`; defaults to the current working directory."
  @spec data_root() :: Path.t()
  def data_root, do: Application.get_env(:symphony_elixir, :data_root) || File.cwd!()

  @spec server_host() :: String.t()
  def server_host, do: Application.get_env(:symphony_elixir, :server_host) || "127.0.0.1"

  @spec operator_token() :: String.t() | nil
  def operator_token, do: Application.get_env(:symphony_elixir, :operator_token)

  @doc "Installation-specific cookie signing key; rotating the operator token invalidates sessions."
  @spec operator_session_secret() :: String.t() | nil
  def operator_session_secret do
    case operator_token() do
      token when is_binary(token) and byte_size(token) > 0 ->
        :crypto.mac(:hmac, :sha512, token, "symphony/operator-session/v1") |> Base.encode64()

      _ ->
        nil
    end
  end

  @spec events_retention_days() :: pos_integer()
  def events_retention_days, do: Application.get_env(:symphony_elixir, :events_retention_days) || 30

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    with {:ok, entry} <- LaneContext.capture() do
      case entry.settings do
        %Schema{} = settings -> {:ok, settings}
        _ -> {:error, {:lane_invalid, entry.error}}
      end
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    LaneContext.current!()

    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec agent_backend_for_state(term()) ::
          {:ok, String.t()} | {:error, {:invalid_agent_backend, String.t(), String.t()}}
  def agent_backend_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    value =
      Map.get(
        config.agent.backend_by_state,
        Schema.normalize_issue_state(state_name),
        config.agent.backend
      )

    validate_agent_backend(value, state_name)
  end

  def agent_backend_for_state(_state_name), do: validate_agent_backend(settings!().agent.backend, "")

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @doc "Installation HTTP port; nil disables HTTP."
  @spec server_port() :: non_neg_integer() | nil
  def server_port, do: Application.get_env(:symphony_elixir, :server_port)

  @doc false
  @spec local_workspace_root() :: Path.t()
  def local_workspace_root do
    Path.expand(settings!().workspace.root, data_root())
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    case LaneContext.snapshot() do
      {:ok, _entry} ->
        with {:ok, settings} <- settings(), do: validate_settings(settings)

      :error ->
        LaneStore.validate(LaneContext.current!())
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  @doc false
  @spec validate_settings(Schema.t()) :: :ok | {:error, term()}
  def validate_settings(settings) do
    if is_nil(settings.tracker.kind) do
      {:error, :missing_tracker_kind}
    else
      with :ok <- Tracker.validate_config(settings.tracker),
           :ok <- validate_environment(settings) do
        validate_backend_commands(settings)
      end
    end
  end

  defp validate_environment(settings) do
    case EnvironmentConfig.runtime(settings) do
      nil ->
        :ok

      config ->
        with {:ok, adapter} <- ExecutionEnvironment.adapter(config.kind),
             :ok <- adapter.validate_config(config.provider) do
          :ok
        else
          _ -> {:error, {:invalid_workflow_config, "invalid worker.environment provider configuration"}}
        end
    end
  end

  defp validate_backend_commands(settings) do
    cond do
      selected_backend?(settings, "codex") and blank_string?(settings.codex.command) ->
        {:error, {:invalid_workflow_config, "codex.command can't be blank"}}

      selected_backend?(settings, "claude") and blank_string?(settings.claude.command) ->
        {:error, {:invalid_workflow_config, "claude.command can't be blank"}}

      true ->
        :ok
    end
  end

  defp selected_backend?(settings, backend_name) do
    [settings.agent.backend | Map.values(settings.agent.backend_by_state)]
    |> Enum.any?(&(to_string(&1) == backend_name))
  end

  defp blank_string?(value), do: not is_binary(value) or String.trim(value) == ""

  defp validate_agent_backend(value, state_name) do
    backend = to_string(value)

    case SymphonyElixir.Agent.module_for(backend) do
      {:ok, _module} -> {:ok, backend}
      {:error, {:invalid_agent_backend, _backend}} -> {:error, {:invalid_agent_backend, state_name, backend}}
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:lane_unavailable, lane_id} ->
        "Lane #{inspect(lane_id)} is not loaded"

      {:lane_invalid, message} ->
        "Invalid lane config: #{message}"

      :no_lane_context ->
        "No lane context for this process"
    end
  end
end
