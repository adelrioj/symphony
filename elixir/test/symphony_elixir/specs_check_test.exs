defmodule SymphonyElixir.SpecsCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SpecsCheck

  test "reports missing @spec for public functions" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def missing(arg), do: arg
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["Sample.missing/1"]
  end

  test "accepts adjacent @spec on public function" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      @spec ok(term()) :: term()
      def ok(arg), do: arg
    end
    """)

    assert SpecsCheck.missing_public_specs([dir]) == []
  end

  test "accepts a spec on a default-argument declaration with multiple guarded clauses" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", ~S"""
    defmodule Sample do
      @spec value(term()) :: term()
      def value(arg \\ :ok)
      def value(arg) when is_atom(arg), do: arg
      def value(arg) when is_integer(arg), do: arg
    end
    """)

    assert SpecsCheck.missing_public_specs([dir]) == []
  end

  test "reports an unspecced default-argument declaration once at its declaration line" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", ~S"""
    defmodule Sample do
      def value(arg \\ :ok)
      def value(arg) when is_atom(arg), do: arg
      def value(arg) when is_integer(arg), do: arg
    end
    """)

    assert [finding] = SpecsCheck.missing_public_specs([dir])
    assert SpecsCheck.finding_identifier(finding) == "Sample.value/1"
    assert finding.line == 2
  end

  test "a later clause spec does not satisfy an unspecced declaration" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", ~S"""
    defmodule Sample do
      def value(arg \\ :ok)
      @spec value(term()) :: term()
      def value(arg), do: arg
    end
    """)

    assert [finding] = SpecsCheck.missing_public_specs([dir])
    assert SpecsCheck.finding_identifier(finding) == "Sample.value/1"
    assert finding.line == 2
  end

  test "a declaration spec does not cover another arity or function" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", ~S"""
    defmodule Sample do
      @spec value(term()) :: term()
      def value(arg \\ :ok)
      def value(arg), do: arg
      def value(left, right), do: {left, right}
      def other(arg), do: arg
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["Sample.value/2", "Sample.other/1"]
  end

  test "a declaration still requires an adjacent spec" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", ~S"""
    defmodule Sample do
      @spec value(term()) :: term()
      defp helper(arg), do: arg
      def value(arg \\ :ok)
      def value(arg), do: helper(arg)
    end
    """)

    assert [finding] = SpecsCheck.missing_public_specs([dir])
    assert SpecsCheck.finding_identifier(finding) == "Sample.value/1"
    assert finding.line == 4
  end

  test "impl on a declaration exempts its clauses but not another function" do
    dir = create_tmp_dir()

    write_module!(dir, "worker.ex", ~S"""
    defmodule Worker do
      @behaviour GenServer
      @impl true
      def init(state \\ [])
      def init(state) when is_list(state), do: {:ok, state}
      def init(state) when is_map(state), do: {:ok, state}
      def other(state), do: state
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["Worker.other/1"]
  end

  test "allows defp without @spec" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def public do
        helper(:ok)
      end

      defp helper(value), do: value
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["Sample.public/0"]
  end

  test "exempts callback implementations marked with @impl" do
    dir = create_tmp_dir()

    write_module!(dir, "worker.ex", """
    defmodule Worker do
      @behaviour GenServer

      @impl true
      def init(state), do: {:ok, state}
    end
    """)

    assert SpecsCheck.missing_public_specs([dir]) == []
  end

  test "honors explicit exemptions list" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def legacy(arg), do: arg
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir], exemptions: ["Sample.legacy/1"])

    assert findings == []
  end

  defp create_tmp_dir do
    unique = :erlang.unique_integer([:positive, :monotonic])
    dir = Path.join(System.tmp_dir!(), "specs-check-test-#{unique}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_module!(dir, rel_path, source) do
    path = Path.join(dir, rel_path)
    File.write!(path, source)
  end
end
