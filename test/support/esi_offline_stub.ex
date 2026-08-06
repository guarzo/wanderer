defmodule WandererApp.Esi.OfflineStub do
  @moduledoc """
  Default ESI seam for the test suite: answers every lookup with an error.

  Set as `:esi_client` in `config/test.exs` so no test reaches the real ESI over
  the network by accident. The seam is read by the Discord enrichers
  (`Discord.NotableItems`, `Discord.CorpTickers`), both of which fail open, so
  an offline answer simply means "not enriched" — which is what an unconfigured
  test wants.

  Tests that care about enrichment override `:esi_client` with
  `WandererApp.Esi.Mock` and script the calls they expect.

  Deliberately silent: the enrichers only log when a lookup *raises*, so the
  default path here adds no noise to unrelated tests.
  """

  def get_character_info(_id, _opts \\ []), do: {:error, :esi_disabled_in_test}
  def get_corporation_info(_id, _opts \\ []), do: {:error, :esi_disabled_in_test}
  def get_alliance_info(_id, _opts \\ []), do: {:error, :esi_disabled_in_test}
  def get_killmail(_id, _hash, _opts \\ []), do: {:error, :esi_disabled_in_test}
  def get_type_info(_id, _opts \\ []), do: {:error, :esi_disabled_in_test}
end
