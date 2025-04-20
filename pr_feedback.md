1. API Documentation (api_documentation.md)
Keep OpenAPI and Markdown in sync
You’ve effectively documented endpoints here, but you’re duplicating much of this in code (controller schemas, Ash resource code interface, inline schemas). Consider using OpenApiSpex to drive both your docs and controller schemas programmatically, reducing drift.

Normalize map‑identification parameters
You noted inconsistency (body vs query). Rather than mixing, standardize on one: e.g. always ?slug= and ?map_id= as query params. Update both docs and controllers to match.

Streamline examples
Rather than repeating full curl blocks for each endpoint, consider a shorter “see above” reference to avoid bloating the file.

2. Test Script (final_working_template_api_test.sh)
Robust error handling
Add set -euo pipefail at the top to fail fast if any command errors or an undefined variable is used.

Parameter validation
Verify $API_TOKEN and $MAP_SLUG are set before proceeding, and bail out with a clear message if not.

Idempotency
Clean up any created templates at the end (via DELETE) so repeated runs don’t accumulate state.
_____________________________________________________________________________________________________



3. Ash Resource Definitions (lib/wanderer_app/api/*.ex)
Avoid manual stubs
Your manual fn _input, _context -> {:ok, %{}} end for bulk_create/bulk_update means no real work is done. Instead, implement actual bulk calls via Ash.Bulk or remove these and call your repo directly.

DRY up repeated accept lists
The same field lists appear in both create and update actions. Extract them into a module attribute (@bulk_fields) and reference it in both places.

Consistency in naming
In MapTemplate, you mix create/get/list_* in the code interface. Consider using consistent verbs (e.g., read_* for all read actions) to match Ash conventions.

Replace ad hoc IO.inspect/IO.puts logging with Logger.debug/1 so you can control verbosity via log levels.

Simplify create_from_map
That function is very long; break it into smaller private functions, each handling one step (validation, normalization, filtering, transformation, creation).

5. Controllers (common_api_controller.ex, map_api_controller.ex)
Remove commented‑out docs
You’ve commented out a ton of @doc blocks; either restore them for clarity or delete entirely to avoid clutter.

Extract schema definitions
You replaced module attributes with dozens of functions like map_system_schema/0. Instead, keep schemas as module attributes (@schema) or define them in a separate Schemas module to keep the controller file focused on routing.

Reduce inline repetition
Each operation block now has a fully inlined schema. Instead, reference shared schemas (e.g., operation :list_systems, responses: [ok: {"…", "application/json", __MODULE__.list_map_systems_response_schema()}]).

Unified error formatting
You’re switching from inspect(reason) to Util.format_error(reason). Pick one and apply consistently across all controller actions.