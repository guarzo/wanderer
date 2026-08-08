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
    default_accept [:map_id, :enabled?, :wh_only, :excluded_systems, :focus_corp_ids]

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

    # Creates the policy row and its :system destination in one transaction.
    # The "a system webhook always exists" invariant cannot be declared — the
    # child's unique identity gives at most one webhook per role, not at least
    # one — so it is enforced here: either both rows exist or neither does.
    create :create do
      primary? true
      argument :webhook_url, :string, allow_nil?: false

      # `manage_relationship`'s `transform:` option isn't available on the
      # installed Ash version (3.9.0) — its opts schema has no such key. This
      # explicit form builds the input map itself instead: one :system child,
      # written in the same transaction as the parent.
      change fn changeset, _context ->
        Ash.Changeset.manage_relationship(
          changeset,
          :webhooks,
          [%{webhook_url: Ash.Changeset.get_argument(changeset, :webhook_url), role: :system}],
          type: :create
        )
      end

      change after_transaction(&__MODULE__.invalidate_cache/3)
    end

    update :update do
      primary? true
      require_atomic? false

      # Explicit, so `default_accept` cannot expose `:map_id`: re-parenting a
      # notification would move it and its webhook children to another map.
      accept [:enabled?, :wh_only, :excluded_systems, :focus_corp_ids]

      change after_transaction(&__MODULE__.invalidate_cache/3)
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

    {:ok, record}
  end

  # Rollback: the rows still exist, so neither the cache nor the workers may be
  # touched. The error passes through untouched.
  def after_destroy(_changeset, other, _context), do: other
end
