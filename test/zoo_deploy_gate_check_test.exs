defmodule WandererApp.ZooDeployGateCheckTest do
  @moduledoc """
  TEMPORARY — delete immediately after use.

  Exists to fail on purpose, so that a run of the 🧪 Test Suite on guarzo/zoo
  concludes `failure`. That is the only way to observe what the 🚀 Zoo Deploy
  workflow does on a red commit: its `if:` guard should skip the job outright,
  which means the `production-deploy` environment is never referenced, no
  approval is requested, and the Fly token is never released.

  See docs/superpowers/plans/2026-08-07-deploy-approval-gate.md, Task 4.
  """
  use ExUnit.Case, async: true

  test "deliberately fails to exercise the deploy workflow's red-commit guard" do
    assert :this_test_is_meant_to_fail == :ok
  end
end
