defmodule WandererApp.Api do
  @moduledoc """
  Legacy API Domain - Backward compatibility alias to V1.

  This domain exists for backward compatibility with existing code that
  references WandererApp.Api directly. It delegates to the V1 API domain
  to maintain the same resource set and behavior.

  @deprecated "Use WandererApp.Api.V1 for new code. This module will be removed after 2025-12-31."
  """

  use Ash.Domain,
    extensions: [AshJsonApi.Domain]

  resources do
    resource WandererApp.Api.AccessList
    resource WandererApp.Api.AccessListMember
    resource WandererApp.Api.Character
    resource WandererApp.Api.Map
    resource WandererApp.Api.MapAccessList
    resource WandererApp.Api.MapSolarSystem
    resource WandererApp.Api.MapSolarSystemJumps
    resource WandererApp.Api.MapChainPassages
    resource WandererApp.Api.MapConnection
    resource WandererApp.Api.MapState
    resource WandererApp.Api.MapSystem
    resource WandererApp.Api.MapSystemComment
    resource WandererApp.Api.MapSystemSignature
    resource WandererApp.Api.MapSystemStructure
    resource WandererApp.Api.MapCharacterSettings
    resource WandererApp.Api.MapSubscription
    resource WandererApp.Api.MapTransaction
    resource WandererApp.Api.MapUserSettings
    resource WandererApp.Api.User
    resource WandererApp.Api.ShipTypeInfo
    resource WandererApp.Api.UserActivity
    resource WandererApp.Api.UserTransaction
    resource WandererApp.Api.CorpWalletTransaction
    resource WandererApp.Api.License
    resource WandererApp.Api.MapPing
    resource WandererApp.Api.MapInvite
  end
end
