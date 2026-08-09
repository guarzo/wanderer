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

  test "an unlabelled default still renders the spacer rows it always did" do
    # Every other call site in the app omits `compact`, so this is the
    # regression guard for them. What it no longer asserts is the literal
    # `for="form_description"`: that was a `for` attribute on a <div>, pointing
    # at an id that exists nowhere in the app. It contributed nothing but a
    # copy-paste artifact, and keeping it pinned here would have blocked giving
    # these comboboxes a real label.
    default = render_field([])

    assert default =~ ~s(<div class="label">)
    assert default =~ ~s(<span class="label-text">)
    refute default =~ "form_description"
  end

  # The bug: `:label` was accepted, stripped from the opts forwarded to
  # LiveSelect, and then never rendered — so every combobox in the app was
  # announced as "combobox, blank". `for` has to target LiveSelect's own text
  # input, whose id it derives as `<field>_text_input`, NOT the `id` we pass
  # (that lands on the LiveComponent wrapper).
  test "a label is rendered and associated with the text input LiveSelect actually creates" do
    labelled = render_field(label: "Home system")

    assert labelled =~ ~s(<label for="f_pick_text_input")
    assert labelled =~ "Home system"
    # …and that id is a real element in the same render.
    assert labelled =~ ~s(id="f_pick_text_input")
    # The empty spacer row is not rendered on top of a real label.
    refute labelled =~ ~s(<span class="label-text"></span>)
  end

  # `compact` exists to make the wrapper exactly as tall as its input, so a
  # neighbouring Add button lines up with the field. A visible label row would
  # undo that, but a missing accessible name is not an acceptable price for it.
  test "a compact label is present for assistive tech but takes no vertical space" do
    compact = render_field(compact: true, label: "Exclude a system")

    assert compact =~ ~s(<label for="f_pick_text_input")
    assert compact =~ ~s(class="sr-only")
    assert compact =~ "Exclude a system"
    refute compact =~ ~s(class="label")
  end
end
