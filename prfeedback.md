⚠︎ Still to do / new issues	Why it matters	Where
Two divergent copies of the module exist (lib/wanderer_app_web/helpers/ash_json_api_forwarder.ex in two directories). The older one still does send_resp(status, Jason.encode!(response)) for 204 responses and deletes by module.	Only one wins at compile‑time (whichever mix picks first); the other silently rots and confuses readers.	
maybe_send_json_response/3 returns send_resp/3 directly but the caller still sets put_resp_content_type("application/json") before delegating. That header is therefore leaked on the 204 branch.	Minor, but strict HTTP clients may still complain.	

Action: delete the obsolete file and move the put_resp_content_type/2 call inside maybe_send_json_response/3.

2  Controllers & Pagination
New behaviour WandererAppWeb.Controller.Paginated is present and CharacterAPIController is already using it – great!
However most large controllers (e.g. MapAPIController, SystemsAPIController) still keep their bespoke paginate/3 logic.

Action: migrate the remaining six controllers to the behaviour; once they compile, delete the duplicated helpers.

3  Fallback controllers
You introduced JsonFallbackController 
, but JsonAction still declares:

elixir
Copy
action_fallback WandererAppWeb.FallbackController
Action: change JsonAction to use the new JSON‑specific fallback and audit any browser controllers that should stay on the old one.

4  Plugs & Feature flags
A new generic FeatureFlag plug is in the tree, but the three hard‑coded plugs (CheckApiDisabled, CheckCharacterApiDisabled, CheckKillsDisabled) are still mounted in router.ex.

SetUser caching has not yet been added – the plug still does a synchronous DB lookup per request.

Action:

Replace the three bespoke plugs with plug FeatureFlag, flag: :public_api_disabled (etc.) and deprecate the originals.

Follow the caching sketch I sent earlier (signed session cookie w/ID + lazy load).

5  Router duplication
lib/wanderer_app_web/router.ex still defines eight near‑identical pipelines and mixes HTML + JSON scopes in one file; the refactor I supplied has not been applied. 

Action: adopt the compositional router (or fold its ideas) so that feature‑flag checks live in one place and SwaggerUI assets come from priv/static/swaggerui to satisfy CSP.

6  CI / Mix‑tasks
✅ mix openapi.export task now exists and the workflow paths include routers/**. Nice. 

⚠️ Remember to add lib/wanderer_app_web/router.ex itself to the path list; otherwise pipeline edits will not trigger the spec diff.

7  Dead‑code & Deprecations
The tree now holds deprecated controllers annotated with use WandererAppWeb.Deprecation – perfect.
But the legacy forwarder copy and old destroy helpers aren’t tagged; they should either:

move to lib/wanderer_app_web/legacy/ or

receive the same use ...Deprecation, removal_date: ~D[2025‑12‑31].

8  Minor polish
Several new modules lack @spec on public functions (e.g. FeatureFlag.init/1).

Credo is now in “strict” mode in credo.exs, but CI still exits 0 on warnings. Flip strict: true or set min_priority: high so HTTP‑204 regressions cannot slip back in.

Overall assessment
You addressed the two critical runtime bugs and laid groundwork (generic plugs, fallback split, pagination behaviour).
The remaining work is mostly code hygiene and duplication removal – important for long‑term maintainability but not production‑blocking.

If you tackle the router consolidation and delete the duplicate forwarder file next, the web layer will be in very good shape.