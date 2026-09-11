defmodule WandererApp.Api.Changes.RevokeMapIntegrationTokens do
  @moduledoc false
  use Ash.Resource.Change

  alias WandererApp.MapIntegrationTokens

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      {:ok, current} = MapIntegrationTokens.lock_map(changeset.data.id)

      owner_changed =
        Ash.Changeset.changing_attribute?(changeset, :owner_id) and
          Ash.Changeset.get_attribute(changeset, :owner_id) != current.owner_id

      if owner_changed or Ash.Changeset.get_attribute(changeset, :deleted) == true do
        MapIntegrationTokens.revoke_for_map!(current.id)
      end

      changeset
    end)
  end
end
