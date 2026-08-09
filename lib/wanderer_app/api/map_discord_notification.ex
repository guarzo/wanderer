defmodule WandererApp.Api.MapDiscordNotification do
  @moduledoc """
  Per-map Discord kill-notification policy.

  Exactly one row per map. Destinations live in `MapDiscordWebhook` children —
  this row holds only what applies to the map as a whole: the kill switch,
  wormhole-only filtering, excluded systems, and focus corporations.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("map_discord_notifications_v1")

    references do
      reference :map, on_delete: :delete
    end
  end

  code_interface do
    define(:create, action: :create)
    define(:update, action: :update)
    define(:destroy, action: :destroy)
    define(:by_id, get_by: [:id], action: :read)
    define(:by_map, action: :by_map, args: [:map_id])
  end

  actions do
    default_accept [
      :map_id,
      :enabled?,
      :wh_only,
      :excluded_systems,
      :focus_corp_ids,
      :route_alerts_enabled?,
      :home_system_id,
      :route_max_jumps
    ]

    defaults [:read]

    # Custom destroy, following map_webhook_subscription.ex:51-58. The default
    # destroy would leave a stale cache entry AND leave the delivery workers
    # draining their queues into webhooks the user just removed.
    destroy :destroy do
      primary? true
      require_atomic? false

      # The webhook ids MUST be captured before the delete runs. PostgreSQL
      # executes ON DELETE CASCADE as a referential action of the DELETE
      # statement itself, not at commit, so by the time an after_action hook
      # runs the child rows are already gone and `Ash.load(record, :webhooks)`
      # returns an empty list. That failure is silent: no error, no stopped
      # workers, and queued messages keep posting to webhooks the user just
      # removed.
      # `stash_webhook_ids/2` must stay in `before_action` for the reason above.
      # The cleanup, though, runs `after_transaction`: an `after_action` hook
      # fires while the DELETE is still uncommitted, so a killmail arriving in
      # that window reloads the configuration, still reads the pre-delete rows
      # and re-caches them for the full TTL — kills keep posting to webhooks the
      # user just removed. On rollback it would also have stopped the workers
      # and evicted the cache for a policy that still exists.
      change before_action(&__MODULE__.stash_webhook_ids/2)
      change after_transaction(&__MODULE__.after_destroy/3)
    end

    # Creates the policy row, optionally with its :system destination in the
    # same transaction.
    #
    # `webhook_url` used to be required, which encoded a "a system webhook
    # always exists" invariant. That invariant was never true after the fact —
    # nothing stops the row being destroyed later — and it had a real cost in
    # the settings UI: route alerts are a separate feature that borrows the
    # same plumbing, and requiring a kill webhook up front meant an operator
    # who only wanted route alerts had to configure a kill channel first.
    #
    # Routing already tolerates the absence. `Router.route/3` resolves the
    # `:system` destination through `usable/1`, which drops on `nil`, so a
    # policy row with no kill destination simply posts no kills.
    create :create do
      primary? true
      argument :webhook_url, :string, allow_nil?: true

      # `manage_relationship`'s `transform:` option isn't available on the
      # installed Ash version (3.9.0) — its opts schema has no such key. This
      # explicit form builds the input map itself instead: one :system child,
      # written in the same transaction as the parent. Skipped entirely when no
      # URL was supplied, rather than passing `[]` — an empty list with
      # `type: :create` is a no-op either way, but the branch says why.
      change fn changeset, _context ->
        case Ash.Changeset.get_argument(changeset, :webhook_url) do
          url when is_binary(url) and url != "" ->
            Ash.Changeset.manage_relationship(
              changeset,
              :webhooks,
              [%{webhook_url: url, role: :system}],
              type: :create
            )

          _absent ->
            changeset
        end
      end

      change after_transaction(&__MODULE__.invalidate_cache/3)
    end

    update :update do
      primary? true
      require_atomic? false

      # Explicit, so `default_accept` cannot expose `:map_id`: re-parenting a
      # notification would move it and its webhook children to another map.
      # The three route fields ARE deliberately in this list — unlike
      # `:map_id` there is no re-parenting risk, and route alert config is
      # meant to be editable the same way the kill-switch fields are.
      accept [
        :enabled?,
        :wh_only,
        :excluded_systems,
        :focus_corp_ids,
        :route_alerts_enabled?,
        :home_system_id,
        :route_max_jumps
      ]

      change after_transaction(&__MODULE__.after_update/3)
    end

    read :by_map do
      argument :map_id, :uuid, allow_nil?: false
      get? true
      filter expr(map_id == ^arg(:map_id))

      # Routing reads the cached value, and the cache stores whatever by_map
      # returned — so the webhooks must be loaded here or routing sees
      # %Ash.NotLoaded{} instead of destinations.
      prepare build(load: [:webhooks])
    end
  end

  validations do
    validate &__MODULE__.validate_home_system_required/2
  end

  attributes do
    uuid_primary_key :id

    # The user-facing kill switch for the whole map. This stays on the parent
    # even though each webhook now has its own enabled? flag: the two mean
    # different things — this one is intent, the child's is destination health —
    # and map-level intent cannot be inferred from the children.
    attribute :enabled?, :boolean, default: true, allow_nil?: false
    attribute :wh_only, :boolean, default: true, allow_nil?: false

    attribute :excluded_systems, {:array, :integer} do
      default []
      allow_nil? false
    end

    attribute :focus_corp_ids, {:array, :integer} do
      default []
      allow_nil? false
    end

    # Route alerts — separate switch from `enabled?`, which gates kills. Ships
    # off: an operator must opt a map in, not discover it firing unannounced.
    attribute :route_alerts_enabled?, :boolean, default: false, allow_nil?: false

    # No "home system" concept exists anywhere else in the codebase (see the
    # design doc's repository-evidence table) — this is where it is defined,
    # scoped to this feature. Nullable: a map with route alerts off need not
    # have one set, and `validate_home_system_required/2` below is what
    # enforces the combination that matters.
    attribute :home_system_id, :integer

    # Inclusive upper bound (design decision 5): "less than 6 jumps" means
    # "at most 5", so the stored number and the UI copy agree.
    attribute :route_max_jumps, :integer do
      default 5
      allow_nil? false
      # 1 is the trivial floor (a route of zero jumps is "already there", not
      # an alert). 20 is a generous ceiling: it is nowhere near a real hauling
      # route in this feature's wormhole-plus-highsec shape, but it stops a
      # typo (e.g. an extra digit) from asking the solver to treat every
      # multi-region path as "qualifying" and firing constantly.
      constraints min: 1, max: 20
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :map, WandererApp.Api.Map do
      attribute_writable? true
      allow_nil? false
    end

    has_many :webhooks, WandererApp.Api.MapDiscordWebhook do
      destination_attribute :notification_id
    end
  end

  identities do
    identity :unique_map_id, [:map_id]
  end

  # Invalidation MUST run after the transaction, not after the action. `create`
  # writes the parent and its :system child in one transaction, so an
  # after_action hook drops the cache entry while both rows are still
  # uncommitted. A killmail arriving in that window reloads the config, reads
  # pre-commit state, finds nothing and caches the NEGATIVE `:none` marker,
  # which then sticks for the cache's 5-minute TTL — a map the user just
  # configured posts nothing for five minutes, with no error anywhere. The same
  # window on an update re-caches the old value.
  #
  # On rollback there is nothing to invalidate: the error result passes through
  # untouched so a failed write cannot evict a still-correct cache entry.
  @doc false
  def invalidate_cache(_changeset, {:ok, record}, _context) do
    WandererApp.ExternalEvents.DiscordDispatcher.invalidate_cache(record.map_id)
    {:ok, record}
  end

  def invalidate_cache(_changeset, other, _context), do: other

  # Update runs the same invalidation, plus one thing the create path does not
  # need: when the record lands with route alerts OFF, the map's watcher must
  # go away. Nothing else evicts it — the dispatcher stops calling notify/1 for
  # a disabled map (discord_dispatcher.ex), so the watcher's own
  # "clear state when disabled" branch never runs, and `config_version/1`
  # deliberately excludes `route_alerts_enabled?` so the stale
  # `{:qualifying, N}` rehydrates byte-identical on re-enable. The result would
  # be a permanently silent map: the route is still open at the same jump
  # count, so the transition table takes the silent branch forever.
  # `stop_watcher/1` stops the process AND evicts the cache entry, which is
  # what makes the next enable start fresh at `:unknown`.
  @doc false
  def after_update(changeset, {:ok, record} = result, context) do
    {:ok, _} = invalidate_cache(changeset, result, context)

    unless record.route_alerts_enabled? do
      WandererApp.ExternalEvents.Discord.RouteWatcherSupervisor.stop_watcher(record.map_id)
    end

    {:ok, record}
  end

  def after_update(_changeset, other, _context), do: other

  @doc false
  def validate_home_system_required(changeset, _context) do
    # get_attribute/2 reads the value the changeset WOULD produce — the new
    # value if it is being set, otherwise the record's current one — so this
    # catches both "enable with no home system yet" and "clear the home
    # system while alerts are still on" in one check.
    enabled? = Ash.Changeset.get_attribute(changeset, :route_alerts_enabled?)
    home_system_id = Ash.Changeset.get_attribute(changeset, :home_system_id)

    if enabled? && is_nil(home_system_id) do
      # The field is NAMED in the message, not left to the `field:` key. The
      # settings tab renders Ash validation errors as a sentence in its own
      # message region (`humanize_error/1`), so a field-scoped message alone
      # surfaced as the orphan "is required when route alerts are enabled" —
      # with no indication of which of the three route fields it meant.
      {:error,
       field: :home_system_id, message: "Home system is required when route alerts are enabled"}
    else
      :ok
    end
  end

  @doc false
  def stash_webhook_ids(changeset, _context) do
    ids =
      case Ash.load(changeset.data, :webhooks) do
        {:ok, %{webhooks: webhooks}} when is_list(webhooks) -> Enum.map(webhooks, & &1.id)
        _ -> []
      end

    Ash.Changeset.put_context(changeset, :webhook_ids, ids)
  end

  @doc false
  def after_destroy(changeset, {:ok, record}, _context) do
    WandererApp.ExternalEvents.DiscordDispatcher.invalidate_cache(record.map_id)

    # Stop every destination's delivery worker: without this, anything already
    # queued keeps posting to webhooks the user has just removed. The ids come
    # from the changeset context because the FK cascade has already deleted the
    # child rows by the time this hook runs — reading them here would return an
    # empty list and quietly stop nothing.
    changeset.context
    |> Map.get(:webhook_ids, [])
    |> Enum.each(fn id ->
      WandererApp.ExternalEvents.Discord.WorkerSupervisor.stop_worker(id)
    end)

    # Stops the map's route-alert watcher AND evicts its cached route_state
    # (RouteWatcherSupervisor.stop_watcher/1 does both): without the eviction
    # a deleted notification's route_state would outlive the process in the
    # TTL-less :discord_route_alert_cache, and a later
    # `MapDiscordNotification.create/1` for the same map would rehydrate that
    # stale state instead of starting fresh at :unknown.
    WandererApp.ExternalEvents.Discord.RouteWatcherSupervisor.stop_watcher(record.map_id)

    {:ok, record}
  end

  # Rollback: the rows still exist, so neither the cache nor the workers may be
  # touched. The error passes through untouched.
  def after_destroy(_changeset, other, _context), do: other
end
