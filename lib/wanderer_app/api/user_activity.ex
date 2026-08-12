defmodule WandererApp.Api.UserActivity do
  @moduledoc false

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource],
    primary_read_warning?: false

  require Ash.Expr

  @ash_pagify_options %{
    default_limit: 15,
    scopes: %{
      role: []
    }
  }
  def ash_pagify_options, do: @ash_pagify_options

  postgres do
    repo(WandererApp.Repo)
    table("user_activity_v1")

    custom_indexes do
      index [:entity_id, :event_type, :inserted_at], unique: true
    end
  end

  json_api do
    type "user_activities"

    includes([:character, :user])

    default_fields([
      :entity_id,
      :entity_type,
      :event_type,
      :event_data
    ])

    derive_filter?(true)
    derive_sort?(true)

    primary_key do
      keys([:id])
    end

    routes do
      base("/user_activities")
      get(:read)
      index :read
    end
  end

  code_interface do
    define(:read, action: :read)
    define(:new, action: :new)
    define(:read_route_attribution, action: :read_route_attribution)
  end

  actions do
    default_accept [
      :entity_id,
      :entity_type,
      :event_type,
      :event_data,
      :user_id,
      :character_id
    ]

    read :read do
      primary?(true)

      pagination offset?: true,
                 default_limit: @ash_pagify_options.default_limit,
                 countable: true,
                 required?: false

      prepare WandererApp.Api.Preparations.LoadCharacter
    end

    create :new do
      accept [:entity_id, :entity_type, :event_type, :event_data, :user_id, :character_id]
      primary?(true)
    end

    # Attribution lookup for Discord route alerts: the newest add event that
    # could have opened a given route, inside a recency window.
    #
    # Both add event types are candidates because a route can open without any
    # system being added — `DiscordDispatcher.do_dispatch/2` re-evaluates on
    # :connection_added and :connection_updated too, so crediting the newest
    # system on the path would regularly name someone who did nothing.
    #
    # `event_data` is matched exactly rather than with a LIKE: the encoding is
    # deterministic (`SecurityAudit.track_map_event/2` drops character_id,
    # user_id and map_id, then `sanitize_metadata/1` stringifies the remaining
    # keys before `Jason.encode!/1`), so callers can reproduce it byte for byte.
    #
    # No pagination, unlike the primary `:read` — this always wants exactly the
    # top row. The `entity_id, event_type` prefix of the
    # [:entity_id, :event_type, :inserted_at] index serves the filter.
    read :read_route_attribution do
      argument(:map_id, :string, allow_nil?: false)
      argument(:since, :utc_datetime_usec, allow_nil?: false)
      argument(:system_event_data, {:array, :string}, allow_nil?: false)
      argument(:connection_event_data, {:array, :string}, allow_nil?: false)

      filter(
        expr(
          entity_type == :map and entity_id == ^arg(:map_id) and
            inserted_at >= ^arg(:since) and
            ((event_type == :system_added and event_data in ^arg(:system_event_data)) or
               (event_type == :map_connection_added and
                  event_data in ^arg(:connection_event_data)))
        )
      )

      prepare(build(sort: [inserted_at: :desc], limit: 1, load: [:character]))
    end

    destroy :archive do
      soft? false
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :entity_id, :string do
      allow_nil? false
      public? true
    end

    attribute :entity_type, :atom do
      default "map"
      public? true

      constraints(
        one_of: [
          :map,
          :access_list,
          :security_event
        ]
      )

      allow_nil?(false)
    end

    attribute :event_type, :atom do
      default "custom"
      public? true

      constraints(
        one_of: [
          :custom,
          :hub_added,
          :hub_removed,
          :system_added,
          :systems_removed,
          :system_updated,
          :character_added,
          :character_removed,
          :character_updated,
          :map_added,
          :map_removed,
          :map_updated,
          :map_acl_added,
          :map_acl_removed,
          :map_acl_updated,
          :map_acl_member_added,
          :map_acl_member_removed,
          :map_acl_member_updated,
          :map_connection_added,
          :map_connection_updated,
          :map_connection_removed,
          :map_rally_added,
          :map_rally_cancelled,
          :signatures_added,
          :signatures_removed,
          # Security audit events
          :auth_success,
          :auth_failure,
          :permission_denied,
          :privilege_escalation,
          :data_access,
          :admin_action,
          :config_change,
          :bulk_operation,
          :security_alert,
          # Subscription events
          :subscription_created,
          :subscription_updated,
          :subscription_deleted,
          :subscription_unknown
        ]
      )

      allow_nil?(false)
    end

    attribute :event_data, :string do
      public? true
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :character, WandererApp.Api.Character do
      allow_nil? true
      attribute_writable? true
      public? true
    end

    belongs_to :user, WandererApp.Api.User do
      allow_nil? true
      attribute_writable? true
      public? true
    end
  end
end
