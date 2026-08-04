defmodule WandererAppWeb.AccessListMemberAPIControllerValidationMessagesTest do
  # Pure formatting - no database or external dependencies.
  use ExUnit.Case, async: true

  alias WandererAppWeb.AccessListMemberAPIController, as: Controller

  defp invalid(errors), do: %Ash.Error.Invalid{errors: errors}

  test "prefixes the field when the error names one" do
    error = %Ash.Error.Changes.InvalidAttribute{field: :role, message: "is invalid"}

    assert Controller.validation_messages(invalid([error])) == ["role: is invalid"]
  end

  test "falls back to the bare message when there is no field" do
    error = %Ash.Error.Invalid.InvalidPrimaryKey{resource: SomeResource, value: "x"}

    assert [message] = Controller.validation_messages(invalid([error]))
    assert is_binary(message)
  end

  test "names the attribute for NoSuchAttribute" do
    error = %Ash.Error.Changes.NoSuchAttribute{attribute: :nonexistent}

    assert Controller.validation_messages(invalid([error])) == ["Invalid attribute: nonexistent"]
  end

  # The point of the change: an arbitrary Ash error must not be serialized into
  # the response. `inspect/1` on one carries the changeset - resource module,
  # internal field names and the submitted attributes (CWE-209).
  # `UnknownError` has no `:message` key, so it hits the final clause and its
  # contents are dropped entirely.
  test "an unrecognised error yields a fixed string, never its contents" do
    error = %Ash.Error.Unknown.UnknownError{error: "internal detail: secret-token-abc123"}

    assert Controller.validation_messages(invalid([error])) == ["Invalid value"]
  end

  test "a struct with neither field nor binary message yields Invalid value" do
    assert Controller.validation_messages(invalid([%{unexpected: :shape}])) == ["Invalid value"]
  end

  test "formats every error in the list" do
    errors = [
      %Ash.Error.Changes.InvalidAttribute{field: :role, message: "is invalid"},
      %Ash.Error.Changes.NoSuchAttribute{attribute: :bogus}
    ]

    assert Controller.validation_messages(invalid(errors)) == [
             "role: is invalid",
             "Invalid attribute: bogus"
           ]
  end
end
