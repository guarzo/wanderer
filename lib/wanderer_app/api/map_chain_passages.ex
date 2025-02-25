defmodule WandererApp.Api.MapChainPassages do
  @moduledoc false

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  import Ecto.Query

  postgres do
    repo(WandererApp.Repo)
    table("map_chain_passages_v1")

    custom_indexes do
      index [:map_id, :character_id]
      index [:map_id, :solar_system_source_id, :solar_system_target_id]
      index [:inserted_at]
    end
  end

  code_interface do
    define(:new, action: :new)
    define(:read, action: :read)
    define(:by_map_id, action: :by_map_id)
    define(:by_connection, action: :by_connection)
  end

  actions do
    default_accept [
      :ship_type_id,
      :ship_name,
      :solar_system_source_id,
      :solar_system_target_id
    ]

    defaults [:create, :read, :update, :destroy]

    create :new do
      accept [
        :ship_type_id,
        :ship_name,
        :solar_system_source_id,
        :solar_system_target_id,
        :map_id,
        :character_id
      ]

      primary?(true)

      argument :map_id, :uuid, allow_nil?: false
      argument :character_id, :uuid, allow_nil?: false

      change manage_relationship(:map_id, :map, on_lookup: :relate, on_no_match: nil)
      change manage_relationship(:character_id, :character, on_lookup: :relate, on_no_match: nil)
    end

    action :by_map_id, {:array, :struct} do
      argument(:map_id, :string, allow_nil?: false)

      run fn input, _context ->
        from(p in __MODULE__,
          join: c in assoc(p, :character),
          where:
            p.map_id == ^input.arguments.map_id and
              c.id == p.character_id,
          group_by: [c.id],
          select: [c, count()]
        )
        |> WandererApp.Repo.all()
        |> Enum.map(fn [character, count] -> %{character: character, count: count} end)
        |> Enum.sort_by(& &1.count, :desc)
        |> then(&{:ok, &1})
      end
    end

    action :by_connection, {:array, :struct} do
      argument(:map_id, :string, allow_nil?: false)
      argument(:from, :string, allow_nil?: false)
      argument(:to, :string, allow_nil?: false)
      argument(:after, :utc_datetime, allow_nil?: false)

      run fn input, _context ->
        from(p in __MODULE__,
          join: c in assoc(p, :character),
          where:
            p.map_id == ^input.arguments.map_id and
              c.id == p.character_id and
              p.solar_system_source_id == ^input.arguments.from and
              p.solar_system_target_id == ^input.arguments.to and
              p.inserted_at >= ^input.arguments.after,
          select: [p, c]
        )
        |> WandererApp.Repo.all()
        |> Enum.map(fn [passage, character] ->
          %{
            ship_type_id: passage.ship_type_id,
            ship_name: passage.ship_name,
            inserted_at: passage.inserted_at,
            character: character
          }
        end)
        |> Enum.sort_by(& &1.inserted_at, :desc)
        |> then(&{:ok, &1})
      end
    end
  end

  aggregates do
    count :jumps, :character do
      filter expr(not is_nil(character_id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :ship_type_id, :integer
    attribute :ship_name, :string
    attribute :solar_system_source_id, :integer
    attribute :solar_system_target_id, :integer

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :map, WandererApp.Api.Map,
      primary_key?: true,
      allow_nil?: false,
      attribute_writable?: true

    belongs_to :character, WandererApp.Api.Character,
      primary_key?: true,
      allow_nil?: false,
      attribute_writable?: true
  end

  def get_passages_by_character(map_id) do
    require Logger

    Logger.info("Getting passages by character for map #{map_id}")

    case by_map_id(%{map_id: map_id}) do
      {:ok, jumps} ->
        Logger.info("Found #{length(jumps)} characters with passages")
        passages = jumps |> Enum.map(fn p -> {p.character.id, p.count} end) |> Map.new()
        Logger.info("Created passages map with #{map_size(passages)} entries")

        # Log the top 5 characters with the most passages
        top_passages =
          passages
          |> Enum.sort_by(fn {_id, count} -> count end, :desc)
          |> Enum.take(5)

        Logger.debug("Top 5 characters with passages: #{inspect(top_passages)}")

        {:ok, passages}
      error ->
        Logger.error("Error getting passages: #{inspect(error)}")
        error
    end
  end
end
