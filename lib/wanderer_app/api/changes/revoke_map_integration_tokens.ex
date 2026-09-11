defmodule WandererApp.Api.Changes.RevokeMapIntegrationTokens do
  @moduledoc false
  use Ash.Resource.Change

  alias WandererApp.MapIntegrationTokens

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      # Evaluate after action changes (notably mark_as_deleted) have run. Keep
      # lifecycle revocation active while disabled so old credentials cannot revive.
      if Ash.Changeset.changing_attribute?(changeset, :owner_id) or
           Ash.Changeset.changing_attribute?(changeset, :deleted) do
        revoke_for_change(changeset)
      else
        changeset
      end
    end)
  end

  defp revoke_for_change(changeset) do
    case MapIntegrationTokens.lock_map(changeset.data.id) do
      {:ok, nil} ->
        Ash.Changeset.add_error(changeset, field: :id, message: "Map no longer exists")

      {:ok, current} ->
        owner_changed =
          Ash.Changeset.changing_attribute?(changeset, :owner_id) and
            Ash.Changeset.get_attribute(changeset, :owner_id) != current.owner_id

        if owner_changed or Ash.Changeset.get_attribute(changeset, :deleted) == true do
          MapIntegrationTokens.revoke_for_map!(current.id)
        end

        changeset

      {:error, reason} ->
        Ash.Changeset.add_error(changeset, reason)
    end
  end
end
