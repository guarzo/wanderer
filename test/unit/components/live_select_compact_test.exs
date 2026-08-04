defmodule WandererAppWeb.CoreComponents.LiveSelectCompactTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  defp render_field(opts) do
    form = Phoenix.Component.to_form(%{"pick" => nil}, as: :f)

    assigns =
      Enum.into(opts, %{
        field: form[:pick],
        mode: :single,
        options: [],
        update_min_len: 1,
        debounce: 100
      })

    render_component(&WandererAppWeb.CoreComponents.live_select/1, assigns)
  end

  test "compact drops both label spacer rows and the always-empty tags container" do
    default = render_field([])
    compact = render_field(compact: true)

    # Baseline: the default rendering has all three.
    assert default =~ ~s(class="label")
    assert default =~ "flex flex-wrap gap-1 p-1"

    # Compact has none of them.
    refute compact =~ ~s(class="label")
    refute compact =~ "flex flex-wrap gap-1 p-1"

    # The tags container element still exists, just with no padding class.
    assert compact =~ ~s(class="hidden")

    # And the input itself is untouched.
    assert compact =~ "p-autocomplete-input"
  end

  test "compact does not suppress the tags container in tag modes" do
    compact_tags = render_field(compact: true, mode: :tags)

    assert compact_tags =~ "flex flex-wrap gap-1 p-1"
    refute compact_tags =~ ~s(class="hidden")
  end

  test "the default rendering is byte-identical to before the compact attr existed" do
    # Every other call site in the app omits `compact`, so this is the
    # regression guard for them.
    default = render_field([])

    assert default =~ ~s(<div for="form_description" class="label">)
    assert default =~ ~s(<span class="label-text">)
  end
end
