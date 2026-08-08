defmodule WandererAppWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias WandererAppWeb.CoreComponents

  # The class string button/1 rendered before it grew a variant system. Every
  # existing call site relies on the default staying exactly this, so it is
  # asserted literally rather than composed from the module's own attributes.
  @legacy_class "phx-submit-loading:opacity-75 p-button p-component p-button-outlined p-button-sm"

  defp button(assigns) do
    render_component(&CoreComponents.button/1, assigns)
  end

  defp class_of(html) do
    [_, class] = Regex.run(~r/class="([^"]*)"/, html)
    class
  end

  describe "button/1 default variant" do
    test "renders the pre-variant class string unchanged" do
      assert class_of(button(%{inner_block: slot("Save")})) == @legacy_class
    end

    test "is identical to an explicit :secondary" do
      assert button(%{inner_block: slot("Save")}) ==
               button(%{variant: :secondary, inner_block: slot("Save")})
    end

    test "still appends a caller-supplied class after the base classes" do
      html = button(%{class: "p-button-danger self-start", inner_block: slot("Remove")})

      assert class_of(html) == @legacy_class <> " p-button-danger self-start"
    end
  end

  describe "button/1 variants" do
    test ":primary is filled — it carries no outline or severity modifier" do
      class = class_of(button(%{variant: :primary, inner_block: slot("Save")}))

      assert class == "phx-submit-loading:opacity-75 p-button p-component p-button-sm"
      refute class =~ "p-button-outlined"
      refute class =~ "p-button-text"
    end

    test ":ghost is borderless and muted" do
      class = class_of(button(%{variant: :ghost, inner_block: slot("Replace")}))

      assert class =~ "p-button-text"
      assert class =~ "p-button-plain"
      refute class =~ "p-button-outlined"
    end

    test ":danger is filled, not merely a tinted outline" do
      class = class_of(button(%{variant: :danger, inner_block: slot("Remove all")}))

      assert class =~ "p-button-danger"
      refute class =~ "p-button-outlined"
      refute class =~ "p-button-text"
    end

    test "every variant keeps the shared structural classes" do
      for variant <- [:primary, :secondary, :ghost, :danger] do
        class = class_of(button(%{variant: variant, inner_block: slot("Go")}))

        assert class =~ "phx-submit-loading:opacity-75"
        assert class =~ "p-button p-component"
        assert class =~ "p-button-sm"
      end
    end

    # `attr :variant, values: [...]` rejects a literal bad variant at compile
    # time, so real call sites can never reach this. A dynamically-passed one
    # still has to fail loudly rather than render an unstyled button.
    test "rejects an unknown variant passed dynamically" do
      assert_raise KeyError, fn ->
        button(%{variant: :destructive, inner_block: slot("Boom")})
      end
    end
  end

  describe "button/1 passthrough" do
    test "keeps type, data and global attributes" do
      html =
        button(%{
          type: "submit",
          data: [confirm: "Sure?"],
          disabled: true,
          inner_block: slot("Save")
        })

      assert html =~ ~s(type="submit")
      assert html =~ ~s(data-confirm="Sure?")
      assert html =~ "disabled"
      assert html =~ "Save"
    end
  end

  defp slot(text) do
    [%{__slot__: :inner_block, inner_block: fn _, _ -> text end}]
  end
end
