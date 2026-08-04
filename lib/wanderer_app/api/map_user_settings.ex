defmodule WandererApp.Api.MapUserSettings do
  @moduledoc false

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource]

  postgres do
    repo(WandererApp.Repo)
    table("map_user_settings_v1")
  end

  json_api do
    type "map_user_settings"

    # Handle composite primary key
    primary_key do
      keys([:map_id, :user_id])
    end

    includes([
      :map,
      :user
    ])

    default_fields([
      :settings,
      :main_character_eve_id,
      :following_character_eve_id,
      :hubs
    ])

    routes do
      base("/map_user_settings")

      get(:read)
      index :read
    end
  end

  code_interface do
    define(:create, action: :create)

    define(:by_user_id,
      get_by: [:map_id, :user_id],
      action: :read
    )

    define(:update_hubs, action: :update_hubs)
    define(:read_by_map, action: :read_by_map)
    define(:read_by_ready_character, action: :read_by_ready_character)

    define(:update_settings, action: :update_settings)
    define(:update_following_character, action: :update_following_character)
    define(:update_ready_characters, action: :update_ready_characters)
  end

  actions do
    default_accept [
      :map_id,
      :user_id,
      :settings
    ]

    defaults [:create, :read, :destroy]

    update :update do
      require_atomic? false
    end

    read :read_by_map do
      argument(:map_id, :string, allow_nil?: false)
      filter(expr(map_id == ^arg(:map_id)))
    end

    # Array containment has to go through a fragment, but it still belongs in an
    # Ash action: the repo previously hand-rolled an Ecto query against
    # `map_user_settings_v1` and rebuilt partial structs from the result.
    read :read_by_ready_character do
      argument(:character_eve_id, :string, allow_nil?: false)

      filter(expr(fragment("? = ANY(?)", ^arg(:character_eve_id), ready_characters)))
    end

    update :update_settings do
      accept [:settings]
      require_atomic? false
    end

    update :update_main_character do
      accept [:main_character_eve_id]
      require_atomic? false
    end

    update :update_following_character do
      accept [:following_character_eve_id]
      require_atomic? false
    end

    update :update_ready_characters do
      accept [:ready_characters]

      # `MapUserSettingsRepo.ready_character_eve_ids/1` caches the map-wide
      # ready set that every connected LiveView reads on each
      # `characters_updated` broadcast. Invalidating here rather than at the
      # four call sites means a new write path cannot forget to.
      #
      # `after_transaction`, not `after_action`: an after_action hook fires
      # while the UPDATE is still uncommitted, so a broadcast arriving in that
      # window reloads the pre-commit rows and re-caches the stale set for the
      # full TTL — the ready flag the user just toggled would appear to revert
      # for five minutes. On rollback the error passes through untouched, so a
      # failed write cannot evict a still-correct entry.
      require_atomic? false

      change after_transaction(&__MODULE__.invalidate_ready_cache/3)
    end

    update :update_hubs do
      accept [:hubs]
      require_atomic? false
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :settings, :string do
      allow_nil? true
      public? true
    end

    attribute :main_character_eve_id, :string do
      allow_nil? true
      public? true
    end

    attribute :following_character_eve_id, :string do
      allow_nil? true
      public? true
    end

    attribute :ready_characters, {:array, :string} do
      allow_nil? true
      default([])
    end

    attribute :hubs, {:array, :string} do
      allow_nil?(true)
      public? true
      default([])
    end
  end

  relationships do
    belongs_to :map, WandererApp.Api.Map, primary_key?: true, allow_nil?: false, public?: true
    belongs_to :user, WandererApp.Api.User, primary_key?: true, allow_nil?: false, public?: true
  end

  identities do
    identity :uniq_map_user, [:map_id, :user_id]
  end

  @doc false
  def invalidate_ready_cache(_changeset, {:ok, record}, _context) do
    WandererApp.MapUserSettingsRepo.invalidate_ready_character_eve_ids(record.map_id)
    {:ok, record}
  end

  def invalidate_ready_cache(_changeset, other, _context), do: other
end
