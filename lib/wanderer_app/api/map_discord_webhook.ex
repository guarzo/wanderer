defmodule WandererApp.Api.MapDiscordWebhook do
  @moduledoc """
  One Discord destination belonging to a `MapDiscordNotification`.

  The parent row holds per-map policy; each child row holds one webhook URL and
  that destination's delivery health. Splitting them means a dead character
  channel disables only itself — before the split, a single `consecutive_failures`
  counter on the parent would have switched off system-kill notifications too.

  The webhook URL is a credential — anyone holding it can post arbitrary messages
  to the channel — so it is encrypted at rest and never rendered back in full.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak]

  require Logger

  @discord_hosts ["discord.com", "discordapp.com", "ptb.discord.com", "canary.discord.com"]

  # Mirrors `WebhookDispatcher`'s threshold (webhook_dispatcher.ex:32): a run of
  # 10 consecutive failures disables this destination. Only a 404 bypasses this.
  @max_consecutive_failures 10

  # Matches the :last_error attribute's max_length constraint, so an
  # unexpectedly long error message is truncated rather than rejected.
  @max_error_length 500

  # Discord caps a channel name at 100 characters and a webhook name at 80.
  # 100 with room to spare for the "#" prefix `ChannelInfo` adds, so a rename
  # upstream can never fail the write that caches it.
  @max_channel_label_length 128

  # Keep the form predicate consistent with the URL attribute's length limit.
  @max_webhook_url_length 2000

  postgres do
    repo(WandererApp.Repo)
    table("map_discord_webhooks_v1")

    references do
      reference :notification, on_delete: :delete
    end
  end

  cloak do
    vault(WandererApp.Vault)
    attributes([:webhook_url])
    decrypt_by_default([:webhook_url])
  end

  code_interface do
    define(:create, action: :create)
    define(:update, action: :update)
    define(:destroy, action: :destroy)
    define(:by_id, get_by: [:id], action: :read)
    define(:by_notification, action: :by_notification, args: [:notification_id])
    define(:set_enabled, action: :set_enabled)
    # `exclude_inputs`: AshCloak turns `webhook_url` into an argument of every
    # action, and a delivery outcome must never be able to rewrite the URL.
    define(:record_success, action: :record_success, exclude_inputs: [:webhook_url])

    define(:record_failure,
      action: :record_failure,
      args: [:error],
      exclude_inputs: [:webhook_url]
    )

    define(:disable, action: :disable, args: [:error], exclude_inputs: [:webhook_url])
    define(:cache_channel_info, action: :cache_channel_info)
  end

  actions do
    default_accept [:notification_id, :role, :webhook_url, :enabled?, :mention_targets]

    defaults [:read]

    create :create do
      primary? true
      validate {__MODULE__.ValidateWebhookUrl, []}
      validate {__MODULE__.ValidateMentionTargets, []}
      change after_transaction(&__MODULE__.invalidate_cache/3)
    end

    update :update do
      primary? true
      require_atomic? false
      # NOT `default_accept`: that would let a caller re-parent a webhook by
      # passing `notification_id`, moving the credential onto another map. It
      # would also defeat `do_invalidate/1`, which resolves the notification
      # from the record *after* the write and so would evict only the new map's
      # cache — the old map would keep routing to a destination it no longer
      # owns for the rest of the TTL. `role` is immutable for the same reason:
      # the unique (notification_id, role) identity is what makes "the system
      # destination" addressable.
      #
      # `mention_targets` is safe to add here unlike `notification_id`/`role`:
      # it carries no ownership semantics, only which snowflakes this
      # destination pings.
      accept [:webhook_url, :enabled?, :mention_targets]
      validate {__MODULE__.ValidateWebhookUrl, []}
      validate {__MODULE__.ValidateMentionTargets, []}

      # A replaced URL is a different endpoint, so the previous one's failure
      # run must not follow it: a destination sitting at 9 consecutive failures
      # would otherwise be disabled by the first hiccup against the new webhook,
      # and would keep displaying the old endpoint's error. AshCloak rewrites the
      # encrypted field into an argument, so this reads the argument; status-only
      # updates leave it absent and are untouched.
      change fn changeset, _ctx ->
        case Ash.Changeset.get_argument(changeset, :webhook_url) do
          url when is_binary(url) ->
            changeset
            |> Ash.Changeset.change_attribute(:consecutive_failures, 0)
            |> Ash.Changeset.change_attribute(:last_error, nil)
            |> Ash.Changeset.change_attribute(:last_error_at, nil)

          _ ->
            changeset
        end
      end

      change after_transaction(&__MODULE__.invalidate_cache/3)
    end

    # Custom destroy, following the destroy action on
    # `WandererApp.Api.MapDiscordNotification`. The default
    # destroy would leave a stale cache entry AND leave this destination's
    # delivery worker draining its queue into a webhook the user just removed.
    #
    # after_transaction for the same reason `invalidate_cache/3` uses it (see
    # the comment above that function), plus one specific to destroy: an
    # after_action hook would stop the delivery worker *before* the commit, so
    # a rolled-back destroy would leave the row alive with its worker killed.
    # Unlike the PARENT resource's destroy — which must stash its children's
    # ids before PostgreSQL runs the FK cascade inside the DELETE — this hook
    # needs nothing but the record it is handed.
    destroy :destroy do
      primary? true
      require_atomic? false

      change after_transaction(&__MODULE__.after_destroy/3)
    end

    read :by_notification do
      argument :notification_id, :uuid, allow_nil?: false
      filter expr(notification_id == ^arg(:notification_id))
    end

    update :set_enabled do
      require_atomic? false
      accept [:enabled?]

      change after_transaction(&__MODULE__.invalidate_cache/3)
    end

    # Deliberately the ONE health action with no cache invalidation: it fires on
    # every successful delivery, so evicting here would drop the routing cache on
    # the hot path and defeat it. None of the four attributes below feeds a
    # routing decision — routing reads `enabled?`, which this never touches. The
    # cost is a `last_delivery_at` in the settings UI that can lag by one TTL.
    update :record_success do
      require_atomic? false
      accept []

      change set_attribute(:last_delivery_at, &DateTime.utc_now/0)
      change set_attribute(:consecutive_failures, 0)
      change set_attribute(:last_error, nil)
      change set_attribute(:last_error_at, nil)
    end

    # Writes back what `ChannelInfo` resolved from Discord, so the settings tab
    # renders a real channel name on open instead of waiting on two HTTP calls
    # per destination.
    #
    # Like `record_success`, deliberately no cache invalidation: none of these
    # attributes feeds a routing decision — routing reads `enabled?` and
    # `webhook_url` — so evicting here would drop the routing cache every time a
    # background refresh confirmed a name that had not changed.
    #
    # Its own action rather than widening `update`'s `accept`: these are cached
    # values written by a background task, not user input, and keeping them off
    # the user-facing action means a crafted form submit cannot claim this
    # destination posts to `#some-innocent-channel`.
    #
    # `accept` alone does not achieve that. AshCloak's `SetUpEncryption`
    # transformer rewrites *every* create/update/destroy action on this
    # resource: it removes the cloaked attribute from `accept` and re-adds it
    # as an action *argument* carrying the encrypting change. So `webhook_url`
    # is submittable here no matter what `accept` lists, and the redirect this
    # action was split out to prevent has to be rejected explicitly.
    update :cache_channel_info do
      require_atomic? false
      accept [:channel_id, :channel_label, :channel_label_source, :guild_id]

      # Checks the argument map rather than `absent(:webhook_url)`: that builtin
      # falls back to the attribute already on the row, so it would reject every
      # call. Only an explicitly submitted argument lands in `arguments`.
      validate fn changeset, _context ->
        if Map.has_key?(changeset.arguments, :webhook_url) do
          {:error,
           field: :webhook_url, message: "cannot be changed while caching channel information"}
        else
          :ok
        end
      end
    end

    # Increments the counter and disables this destination once the run reaches
    # @max_consecutive_failures.
    #
    # Both writes are atomic SQL expressions, so the increment is a single
    # UPDATE with no preceding read: concurrent deliveries (including on other
    # nodes) cannot lose an increment, and the threshold is evaluated against the
    # row's committed value rather than a possibly-stale in-memory copy.
    #
    # `require_atomic? false` remains because :last_error is set from an
    # argument in a regular change; the two counter writes are atomic regardless.
    update :record_failure do
      require_atomic? false
      accept []
      argument :error, :string, allow_nil?: false

      change atomic_update(:consecutive_failures, expr(consecutive_failures + 1))

      # Evaluated in SQL as a CASE over the pre-update value, so it agrees with
      # the increment above even if another delivery commits in between.
      change atomic_update(
               :enabled?,
               expr(
                 if consecutive_failures + 1 >= ^@max_consecutive_failures do
                   false
                 else
                   enabled?
                 end
               )
             )

      change fn changeset, _ctx ->
        changeset
        |> Ash.Changeset.change_attribute(
          :last_error,
          changeset |> Ash.Changeset.get_argument(:error) |> String.slice(0, @max_error_length)
        )
        |> Ash.Changeset.change_attribute(:last_error_at, DateTime.utc_now())
      end

      change after_transaction(&__MODULE__.invalidate_cache/3)
    end

    # Immediate disable, used only for a 404 (webhook deleted upstream, will
    # never recover). Everything else goes through record_failure's threshold.
    update :disable do
      require_atomic? false
      accept []
      argument :error, :string, allow_nil?: false

      change set_attribute(:enabled?, false)
      change set_attribute(:last_error_at, &DateTime.utc_now/0)

      change fn changeset, _ctx ->
        Ash.Changeset.change_attribute(
          changeset,
          :last_error,
          changeset |> Ash.Changeset.get_argument(:error) |> String.slice(0, @max_error_length)
        )
      end

      change after_transaction(&__MODULE__.invalidate_cache/3)
    end
  end

  changes do
    # Ciphertext is stable across status writes but changes whenever the URL is
    # replaced. Match it in the SQL UPDATE so an in-flight outcome for the old
    # endpoint cannot affect the replacement (it fails with a StaleRecord error
    # instead). Unlike updated_at locking, this still permits concurrent failure
    # increments for the same endpoint.
    change fn changeset, _context ->
      if changeset.action.name in [:record_success, :record_failure, :disable] do
        Ash.Changeset.filter(changeset,
          encrypted_webhook_url: changeset.data.encrypted_webhook_url
        )
      else
        changeset
      end
    end

    # AshCloak's generated argument does not inherit sensitive?. Cast failures
    # (for example max_length) therefore retain the credential in error.value,
    # which callers may log even though Ash redacts the enclosing changeset.
    change fn changeset, _context ->
      errors =
        Enum.map(changeset.errors, fn
          %Ash.Error.Changes.InvalidArgument{field: :webhook_url} = error ->
            %{error | value: Ash.Helpers.redact(error.value)}

          error ->
            error
        end)

      %{changeset | errors: errors}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      constraints one_of: [:system, :character, :route, :rally]
    end

    attribute :webhook_url, :string do
      allow_nil? false
      sensitive? true
      constraints max_length: @max_webhook_url_length
    end

    attribute :enabled?, :boolean, default: true, allow_nil?: false

    attribute :last_delivery_at, :utc_datetime
    attribute :last_error, :string, constraints: [max_length: @max_error_length]
    attribute :last_error_at, :utc_datetime
    attribute :consecutive_failures, :integer, default: 0, allow_nil?: false

    # Cached Discord identity for this destination, resolved by
    # `WandererApp.ExternalEvents.Discord.ChannelInfo` and refreshed in the
    # background. None is a credential and none is `sensitive?`: the whole
    # point is that they are safe to render on a screen that gets screenshotted,
    # unlike the webhook id the settings tab used to show. `channel_id` is a
    # public guild snowflake, and `channel_label` is the channel or webhook name
    # the operator already sees in Discord.
    #
    # Nullable and always re-derivable: an instance with no bot token, or a
    # webhook Discord will not answer for, simply leaves them nil and renders a
    # masked hint. Nothing routes off any of these values.
    attribute :channel_id, :string
    attribute :channel_label, :string, constraints: [max_length: @max_channel_label_length]

    # Guild this destination's channel belongs to, decoded from the same
    # `GET /channels/{id}` response that yields `channel_label`. Cached here so
    # the mention typeahead can scope its role/member search on tab open without
    # a round trip. A public snowflake, never a credential.
    #
    # nil whenever the bot could not answer for the channel — which is exactly
    # when the typeahead is unavailable anyway, so the same nil drives the
    # manual-entry fallback.
    attribute :guild_id, :string

    # Which tier produced `channel_label`: `:channel` for a real `#name` read
    # from `GET /channels/{id}`, `:webhook` for the webhook's own nickname.
    #
    # Persisted rather than inferred from a leading "#", because a webhook may
    # legitimately be named "#anything" and the UI must not claim that is a
    # channel. nil means the row predates this column: unknowable after the
    # fact, so `ChannelInfo` reports it as `:unknown`, makes no claim in the UI,
    # and schedules a refresh that fills it in.
    #
    # `:atom` with `one_of` follows `role` above; a bare `:string` cannot carry
    # the constraint (Ash's string type takes only length/match options).
    attribute :channel_label_source, :atom do
      constraints one_of: [:channel, :webhook_name]
    end

    # Guild-scoped snowflakes to ping on this destination — see the design
    # doc's "Where configured targets live": these belong on the webhook row,
    # not anywhere map- or instance-wide, because a role/user id from one
    # guild is meaningless (and unrenderable) in another.
    attribute :mention_targets, {:array, :string} do
      default []
      allow_nil? false
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :notification, WandererApp.Api.MapDiscordNotification do
      attribute_writable? true
      allow_nil? false
    end
  end

  identities do
    identity :unique_notification_role, [:notification_id, :role]
  end

  @doc """
  Returns true when the URL is a syntactically valid Discord webhook endpoint.
  Exposed so the LiveView form can validate before submitting.
  """
  def valid_webhook_url?(url) when is_binary(url) do
    trimmed = String.trim(url)

    # Control characters are rejected rather than stripped: URI.parse/1 keeps
    # them inside the path, so ".../api/webhooks/1/abc\ndef" would clear the
    # segment checks and reach Finch as a request URL. Surrounding whitespace is
    # tolerated because Ash's :string type trims before the value is stored.
    String.length(trimmed) <= @max_webhook_url_length and
      not String.match?(trimmed, ~r/[[:cntrl:]]/u) and parsed_webhook_url?(trimmed)
  end

  def valid_webhook_url?(_), do: false

  defp parsed_webhook_url?(url) do
    # URI.parse/1 accepts malformed ports; URI.new/1 rejects invalid request
    # URLs before a saved credential can reach the HTTP client.
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, port: 443, userinfo: nil, path: path}}
      when is_binary(host) and is_binary(path) ->
        # Hostnames are case-insensitive and URI.new/1 keeps the host as typed,
        # so a pasted "https://Discord.com/..." must still match the allowlist.
        String.downcase(host) in @discord_hosts and valid_webhook_path?(path)

      _ ->
        false
    end
  end

  defp valid_webhook_path?(path) do
    # Numeric API-version variants and an optional trailing slash are allowed;
    # query parameters (for example thread_id) are not part of the path.
    String.match?(path, ~r{\A/api/(?:v[0-9]+/)?webhooks/[0-9]+/[^/]+/?\z})
  end

  defmodule ValidateWebhookUrl do
    @moduledoc false
    use Ash.Resource.Validation

    @impl true
    def validate(changeset, _opts, _context) do
      # AshCloak rewrites the encrypted field into a changeset *argument* (the
      # stored attribute is `encrypted_webhook_url`, and `webhook_url` becomes a
      # calculation), so the argument is what carries the value being written.
      #
      # Distinguish an omitted update from an explicit nil/blank value: only the
      # former is a status-only write. Encrypting nil still produces non-null
      # ciphertext, so a nil that slipped through would bypass the column's
      # NOT NULL and store an undeliverable credential.
      case Ash.Changeset.fetch_argument(changeset, :webhook_url) do
        :error when changeset.action_type == :update ->
          :ok

        argument ->
          url =
            case argument do
              {:ok, value} -> value
              :error -> nil
            end

          if WandererApp.Api.MapDiscordWebhook.valid_webhook_url?(url) do
            :ok
          else
            {:error,
             field: :webhook_url,
             message:
               "must be a Discord webhook URL, e.g. https://discord.com/api/webhooks/{id}/{token}"}
          end
      end
    end
  end

  defmodule ValidateMentionTargets do
    @moduledoc false
    use Ash.Resource.Validation

    alias WandererApp.ExternalEvents.Discord.Mentions

    @impl true
    def validate(changeset, _opts, _context) do
      case Ash.Changeset.get_argument_or_attribute(changeset, :mention_targets) do
        nil ->
          :ok

        targets when is_list(targets) ->
          if Enum.all?(targets, &Mentions.valid_target?/1) do
            :ok
          else
            {:error,
             field: :mention_targets,
             message: "each entry must match user:<id> or role:<id> (17-20 digit snowflake)"}
          end

        _ ->
          :ok
      end
    end
  end

  # after_transaction, not after_action: an after_action hook evicts the cached
  # config while this row is still uncommitted, so a killmail arriving in that
  # window reloads pre-commit state and re-caches it — the old URL on an update,
  # or the negative `:none` marker if the parent was created in the same
  # transaction. Either sticks for the cache's 5-minute TTL. On rollback the
  # error result passes straight through: there is nothing to invalidate, and
  # evicting anyway would only discard a still-correct entry.
  @doc false
  def invalidate_cache(_changeset, {:ok, record}, _context) do
    do_invalidate(record)
    {:ok, record}
  end

  def invalidate_cache(_changeset, other, _context), do: other

  @doc false
  def after_destroy(_changeset, {:ok, record}, _context) do
    do_invalidate(record)
    # Stop this destination's delivery worker too: without this, anything already
    # queued keeps posting to a webhook the user has just removed.
    WandererApp.ExternalEvents.Discord.WorkerSupervisor.stop_worker(record.id)
    {:ok, record}
  end

  def after_destroy(_changeset, other, _context), do: other

  defp do_invalidate(record) do
    case Ash.get(WandererApp.Api.MapDiscordNotification, record.notification_id) do
      {:ok, notification} ->
        WandererApp.ExternalEvents.DiscordDispatcher.invalidate_cache(notification.map_id)

      error ->
        # Swallowed rather than raised — a failed eviction must not fail the
        # write that already committed — but logged, because the consequence is
        # a routing cache that serves the previous destination for the rest of
        # the TTL, which is otherwise indistinguishable from "the user's change
        # did nothing".
        Logger.warning(
          "[MapDiscordWebhook] cache not invalidated for webhook #{record.id}: #{inspect(error)}"
        )

        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "[MapDiscordWebhook] cache invalidation raised for webhook #{record.id}: " <>
          Exception.message(exception)
      )

      :ok
  end
end
