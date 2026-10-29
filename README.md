# ALA Lint (ala_lint_ruby)

A static-analysis linter that scores a Ruby or Rails codebase against the **ALA Checklist, Ruby and
Rails edition** (`../ala_checklist/ala_checklist_ruby.md`): R1–R11, with the object-oriented
concerns that edition adds (every edge kind, owned interfaces, shared entities, the composition's
fields, Rails' models, callbacks, templates and helpers). It reads `.rb` and `.html.erb` files with
Prism, needs no Rails and no gems beyond Ruby's own, and reports each finding with a location, the
rule and the section of Spray's site it rests on.

It is the Ruby counterpart of `../ala_lint_elixir` with the same command-line shape, but it works on
the syntax tree directly: there is no intermediate encoding and no `ala.encode` step.

> An independent, unofficial implementation based on John Spray's
> [Abstraction Layered Architecture](https://www.abstractionlayeredarchitecture.com/).
> Not affiliated with or endorsed by the author.

## Run it

```
bin/ala_lint --root path/to/app            # score app/, lib/ and config/routes.rb
bin/ala_lint lib                            # a subtree (paths are relative to --root, default .)
bin/ala_lint --root app --strict            # score the obtainable advisory checks too
bin/ala_lint --root app --super-strict      # and the aspirational one (R11)
bin/ala_lint --root app --min-score 80      # exit 1 below 80 (the CI gate)
bin/ala_lint --root app --require-layers    # exit 1 if any unit matches no layer
bin/ala_lint --root app --enforce r7        # promote one check to scored
bin/ala_lint --root app --disable r3        # turn one off (the report says so)
bin/ala_lint --root app --set height.max=4  # retune a threshold
bin/ala_lint --root app --set r11.calls=wired_only  # R11 reads hand-offs into wired parts only
bin/ala_lint --root app --preset light_ala  # light ALA: the port, wiring and composition checks off
bin/ala_lint --root app --format json
bin/ala_lint --list-checks                  # every check, its tier and threshold
bin/ala_lint --root app --explain --strict  # what this run scores, only reports, and leaves to a reader
bin/ala_lint --help                         # unknown flags fail with the usage, never silently
rake test                                   # the linter's own suite (Minitest)
```

Ruby 4.0 (Prism ships with it); `.tool-versions` pins 4.0.7 for asdf.

`--explain` prints a guide to the run that its flags and `.ala_lint.rb` describe, and reads no
code. It has three parts: the checklist rules the run scores, each with its § citation and the
checks that score it; the rules and checks it only reports; and what still applies that no check
reads. That last part always has R8, has the judgement half of each other rule the run adopts, and
under `--preset light_ala` has V59's conventions, rules 11 and 12 included, since this linter has no
check for them. A rule whose checks are all off is left out, and the last line names it.

## Settings (`.ala_lint.rb`)

A Ruby file at the project root that evaluates to a Hash. The **layer map** is the one thing the
linter can't do without for the altitude checks (R1), R3, R10 and R11: layers are a design decision a
team *declares*, top first; inferring them from the call graph would make R1 true by construction.

```ruby
{
  layers: [
    # the first layer is the composition unless `composition:` says otherwise
    { name: :application, paths: [%r{\Aapp/ala/screens/}, %r{\Aapp/controllers/}, %r{\Aapp/views/(?!components/)}] },
    { name: :domain,      paths: [%r{\Aapp/ala/domain_abstractions/}, %r{\Aapp/views/components/}, %r{\Aapp/helpers/}] },
    { name: :paradigms,   paths: [%r{\Aapp/ala/programming_paradigms/}] },
    { name: :foundation,  paths: [%r{\Aapp/ala/foundation/}, %r{\Aapp/models/}], uses: [/\AApplicationRecord\z/], peer_ok: true }
  ],
  identity_models: %w[Cart],        # belongs_to these is sharing an identity key, and their dependent: is lifecycle (R10)
  paths: %w[app lib config/routes.rb],
  exclude: [%r{/views/layouts/}],
  min_score: 80,
  checks: { r7: :scored, height: { max: 4 }, r11: :off }
}
```

A unit is assigned to a layer most-specific-wins: its own `# @ala_layer name` comment above the
class, then a `uses:` match on its superclass or mixins (a record is persistence wherever it sits),
then the first layer whose `paths:` or `namespaces:` pattern matches. Anything left is **unassigned**:
reported loudly, skipped by the layer-aware checks, and a failure under `--require-layers`.
`peer_ok: true` allows same-layer edges inside a layer (the bottom usually), `composition: true`
marks a layer as a composition (the application, or a Features layer), which gets the R11 checks and
may hold application literals.

A check's setting is a level (`:off`, `:advisory`, `:scored`) or a hash with a `level:` and
thresholds. The CLI flags override the file for one run, and a run that disabled or downgraded a
check says so in its parameter echo.

R11 takes one setting that is a reading, not a number: `calls:` is `:all` (the default) or
`:wired_only`, as in `checks: { r11: { level: :advisory, calls: :wired_only } }` or
`--set r11.calls=wired_only`. Any other value fails the run. `:wired_only` is for a composition that
wires only the parts two or more compositions place and calls the rest (ALA Light, subset 3): a
call-and-return there is the design, not handled data.

A **preset** is a reading of the checklist, set by `preset: :light_ala` in the file or
`--preset light_ala` for one run (the flag wins; an unknown name fails the run). Light ALA keeps
layering, dependency direction, calibration at the top, named rules and the clone check, and drops
ports, wiring and composition-only pages. The preset is a whitelist of the checks it adopts, so a
check added to the linter later is off under it until someone judges it part of the reading; today
that leaves off r9, r10, r10_aggregate, r11, r11_share, app_share, ports and ports_unwired. r9 goes
whole, its `ENV`/`Rails.configuration` lookups below the composition included. A level set for a check in
`checks:`, `--enforce` or `--disable` still wins over the preset; a hash with thresholds only (a
`calls:`) leaves the preset's `:off`. The parameter echo names the preset. The Elixir edition's
light-ALA checks for builder literals and stale-session writes have no Ruby counterpart yet.

A check's level comes from the last source that sets one, in this order: the preset, the `checks:`
level in `.ala_lint.rb`, `--enforce`, `--disable`. When two of them ask for different levels, the
report opens with a block that names each source, the level it asked for and the one used, and
`params.conflicts` in `--format json` holds the same list. Sources that agree, and a hash with
thresholds only, are not a conflict, and a run without one prints what it printed before. V08 and
V09 set an R11 level, so under `--preset light_ala` they show the second line below.

```
settings conflict: 2 checks set differently by more than one source; the later source won
  clone      file checks: off   --enforce: scored   -> using --enforce (scored)
  r11        preset light_ala: off   file checks: advisory   -> using file checks (advisory)
```

## Accepting a finding by hand (`ala:accept`)

Several checks turn on a judgement the tool can't make: whether a word below the composition is the
product's (hoist it) or the abstraction's domain's own (keep it; the checklist's R3 exception), whether
a controller branch is routing or logic, whether a shared type is a ground symbol. A comment on the
line above records the reviewer's call where the code is, names the exact check, and takes that line
(or the next N lines) out of the score for that check only:

```ruby
# ala:accept r3 -- "Out of stock" is retail's word, not this store's (R3, domain vocabulary)
def label = "Out of stock"

# ala:accept r3,r6 lines=2 -- two checks, the next two lines
```

```erb
<%# ala:accept r11 -- the one loop this page keeps, until a rows component exists %>
<% rows.each do |row| %>...<% end %>
```

For words, there is a declaration instead of a comment. A lower abstraction that owns some
vocabulary (a retail stock badge's "Out of stock", a pager's "Next") keeps it in a constant named
`INHERENT_...` (or a class-level `@inherent_...`), and R3 reads nothing inside that value as product
text; the declaration says the reviewer judged the words the abstraction's own, per the checklist's
domain-vocabulary exception. `--list-accepted` lists these declarations too.

```ruby
class StockBadge
  INHERENT_LABELS = { in_stock: "In stock", low_stock: "Only %{n} left!", out_of_stock: "Out of stock" }.freeze
end
```

The check names are the ones `--list-checks` prints; an unknown one fails the run. Accepted findings
leave the score and the rules-met count, and the report says how many were accepted and under how
many comments. `--list-accepted` prints every comment with the findings it covers, and marks the
ones that cover nothing, which is how a stale acceptance shows up after the code moved. The JSON
output carries them as `accepted` and `acceptances`.

## What a unit is

The checklist's encoding is function-centric and its OO reading makes the class the natural unit.
Here a **unit** is a class or module with its own members (a nested class, enum or value type
qualifies to its enclosing unit, so a feature's own small types are its inside, not peers), an ERB
template (a page or a partial), a `Name = Data.define(...)` type, or a file of top-level statements
(`config/routes.rb`). A module that only nests other classes is a namespace, not a unit.

Constants are resolved the way Ruby looks them up (lexical nesting, then the unit's mixins, then the
top level), so `include DomainAbstractions` in a screen makes `CartLines.new` an edge to
`DomainAbstractions::CartLines`. A `render "components/x"` in a template is an edge to the partial;
a bare call to a method some `*Helper` module defines is an edge to that helper.

## The checks and their precision

A green run means "no gross, mechanically-detectable coupling at the module-graph and literal
level". The checklist lists what each rule leaves to a human; so does this table.

| check | what it flags | precision |
|---|---|---|
| **r1** | with a layer map: every edge kind the OO checklist lists that doesn't drop, between units: a call, a `new`, a superclass (your own class; a framework base such as `ApplicationRecord` is configuring a lower framework and allowed), `include`/`extend`/`prepend`, a constant, a `render` of a peer partial, a helper call from a component; a model callback reaching another unit. Without a layer map: unit dependency cycles | exact on what the syntax shows; a call on an injected object is invisible, as the checklist says |
| **r2** | class variables, globals, `Thread.current`, `Current.*` read below the composition, class-level memoisation (`@x ||=` in a singleton method) below the composition and outside the bottom layer | exact; aliasing at run time is not visible |
| **r3** | with a layer map, below the composition: numeric literals (0, 1, −1, 2 skipped; 10/100/1000 skipped beside `*` or `/`; `raise` arguments skipped), message text (two or more words with a capital or sentence punctuation; CSS class strings skipped), sentences built by interpolation, `validates ... message:`, `I18n.t` with a literal key, `currency:`/`unit:`/`locale:` codes, keyword defaults that look like product decisions and a peer `new` as a default; in a lower layer's template, text nodes and label-like attributes (`placeholder`, `title`, `aria-label`). The bottom layer's words are exempt (a paradigm's own diagnostics) | heuristic: the tool can't tell an application literal from an intrinsic one |
| **r4** | a composition-layer class assigning a field outside `initialize` and outside a wiring block or a wiring table's arm (a controller handing the view a constant, a parameter, a literal or a landed value is exempt; memoising a `new` is exempt); a domain class exposing a collection it mutates through `attr_reader`; `Mutex`/`Monitor` in a domain class; `instance_variable_get/set` on another object | exact on shape |
| **r5** | the same identifier-like string in two units unless both are the composition (render paths, `class:`/`data:` values, string-method arguments and a few MIME/HTTP words skipped; a template's `id=`, `name=`, `data-controller=` values count); a `$2.99` label whose cents are an integer literal somewhere; `send`/`public_send` with a name built from a string | heuristic: textual duplication, not semantic agreement |
| **r6** | role names (`*Service`, `*Manager`, `*Helper` outside `app/helpers`, `*Handler`, `*Utils`), meaningless method names (`f1`, `process2`, `tmp`, single letters), a public method that is one operator over its parameters (a predicate, or a method over its own configured field, is spared) | weak heuristic; naming is judgement |
| **r9** | a peer module included as an interface; subclassing an abstract base (`raise NotImplementedError`); `respond_to?(:x)` on a collaborator where `x` isn't a paradigm's message; `Rails.configuration`, `Rails.application`, `ENV`, `Import[]`, `Dry::Container` below the composition | exact on these forms; whether outputs announce is judgement |
| **r10** | a record or value type read by two units of one peer-forbidden layer (constructing one isn't reading it); `has_many`/`has_one`; `belongs_to` a model not listed under `identity_models`. Exempt as the identity's lifecycle (deleting it removes the rows keyed by it): a `has_many`/`has_one` with `dependent:` on a model listed under `identity_models`, or one the composition configures on a record (`Product.has_many :cart_items, dependent: :delete_all`), as long as no unit reads or walks through it: a call of the association's name, a query naming it (`includes`, `joins`, `preload`, `eager_load`, `left_joins`, `references`) or a `through:` it. A read is reported with where it is | heuristic on associations; the read is found by name, so a same-named method elsewhere counts as one |
| **layer** | an `@ala_layer` tag naming no declared layer | exact |
| **r7** (advisory) | a private method named nowhere in the project (calls, symbols, `&:name`; a dynamic `send` anywhere turns it off) | exact on names |
| **passthrough** (advisory) | a public method whose body only renames another unit's method with the same arguments; delegation over a field is reported as the §7.16 shape | heuristic |
| **tramp** (advisory) | a public parameter never read, only passed bare to another unit's method that passes it on again (R6's "should") | heuristic; only const-receiver calls resolve |
| **subscribe** (advisory) | below the composition and above the bottom: `subscribe`, `turbo_stream_from`, `broadcast_*_to` with a literal topic | exact |
| **ports** (advisory) | a class with `output`/`input` ports its header comment doesn't name (§5.8.2). A class nested in a unit (`module Live` holding `class Feed`) is held to its own header and blamed at its own line; the enclosing module answers only for ports it declares itself | exact; the port macros are this edition's Foundation |
| **ui_io** (advisory) | a template below the composition calling a record model or a store method | heuristic |
| **clone** (advisory), **clone_inside** (reported) | the same logic in two methods, names aside: each method body is read as a sequence of syntax nodes in which local names, parameters, fields and literal values are placeholders while call, constant and symbol names stay; every pair of methods is aligned locally (Smith-Waterman), so a copied run inside a larger method counts as well as a whole copy, and an edited copy counts while at least 80% of the aligned nodes agree; at least 16 matched nodes (`clone.min_nodes`, `clone.min_similarity`). Methods whose matches cover the same stretch are one finding, at the first location listed. Not read: a composition's `initialize` and `parts` (placing parts), wiring-table arms, and bare `render`/`redirect_to` and the other routing calls, because they are alike by design. Across units it is `clone`; inside one unit it is `clone_inside`, never scored by a tier, because the checklist leaves an abstraction's interior to its author (R7, "little balls of mud"). Reported under R7 as this linter's reading: the checklist has no rule against copied logic; the message quotes Spray's "no other elements should know about this one thing" (§7.25), which the checklist cites under R5 and R6 | heuristic: structure and names, not meaning. A repeated idiom (a loop that walks units and flags) matches as well as a copied concept, and a shared output shape (two summaries a template reads) looks like shared logic. 16 is the size of a four-key hash of method reads, the smallest known copy; 20 drops most idiom matches and misses that copy |
| **r10_aggregate** (advisory) | a lower-layer type read by two units of a peer-forbidden layer above it; a `Data`/`Struct` type that defines behaviour of its own (a `Money` with `+`) is an abstraction both ends depend on and is exempt, a bare field bag is a DTO and prompts | prompt |
| **height**, **module_size**, **module_avg**, **app_share** | thresholds (5 hops between units, 500 lines, 100-line average, 20% of functions) | metrics |
| **public_surface** (reported) | a unit whose public ports are an outlier among its own layer's units: more than max(`floor`, Q3 + `k` × IQR), where Q1 and Q3 are the quartiles (linear interpolation) of the port counts of the layer's units that have any ports, and `floor` (10, as in the Elixir linter) keeps a small app quiet (`public_surface.floor`, `public_surface.k`, default 1.5: Tukey's fence). A port is a public instance method, not counting `initialize` or a message a paradigm declares (a public instance method of a paradigm-layer module, such as a wiring module's `parts`); a method whose body only dispatches on a parameter's shape (`case change in { stock: } ... in { amount: }`) is one port per pattern. Not counted: compositions, framework subclasses, and calibration modules, whose every public method returns a literal, a constant, a literal list or map, or a value picked from a literal table by a key argument (a table of the store's values, not an abstraction with ports). Never scored by a tier: Spray gives no count, so it is a prompt for the R6/R7 judgement | metric relative to the app; floor 10 is this linter's choice |
| **r11** (aspirational) | in composition units, in a method or in a lambda a constant holds (attributed to the constant): branches (a branch, `case`/`when` or `case`/`in` included, whose arms only redirect, render or hand the view a constant, parameter, literal or landed value is routing and exempt; a wiring table, `case [part, output]` in a method named `wire` whose arms match two symbols, is wiring; an arm may alternate wires, `[ :a, :x ] \| [ :b, :y ]`, or match every other output of a part with `[ :a, _ ]`), arithmetic, iteration with a block, one lower call's result bound and handed to another or passed straight in (`new`, wiring calls including `run` and the part calls fed to it, `params`/`session`/`flash` and rendering exempt; under `r11.calls=wired_only` also a hand-off into a field or local the composition never lists in `parts`, hands to `run` or joins with `wire_to`, a called part); in composition templates: branches (a `case`/`if` whose arms only render or hold markup picks a view and is routing; write it with `-%>` so the compiled Ruby parses), comparisons, arithmetic, loops, calls into lower units. In both, choosing what runs by a name built at run time, the same branch out of sight: `render` with an interpolated or concatenated name (`render "portal/#{step}"`), a `partial:`/`template:` option (on any call, `turbo_stream.replace` too; on `render` also `layout:`, `action:`, `file:` when it has no positional name) that isn't a fixed name, and `send`/`public_send`/`__send__`/`method`/`const_get` with, or `constantize`/`safe_constantize` on, a name that isn't fixed. A fixed name is a literal, a constant, a value picked from a literal table of names (`VIEWS.fetch(step)`, a hash or list whose values are strings, symbols, constants or lambdas: a closed dispatch table is routing), a local or field every assignment of which is one, or a parameter every caller in the project passes one for. `render x` with a plain variable is not read, because it also renders objects | heuristic; which departures the framework forces is judgement. A name read from the app's configuration (`Rails.configuration.x.gateway.constantize`, `ENV`) is fixed at boot and counts as fixed |
| **ports_unwired**, **r11_share**, **unassigned** | report-only prompts | — |
| **r8** | not checked: judgement | — |

Not read: JavaScript (Stimulus controllers), so a contract between a template's `data-action` and
a controller's method is a human's to check; and SQL, migrations and schema.

## Tiers and scores

- **default**: the required checks score (R1, R2, R3, R4, R5, R6, R9, R10, layer validity).
- **`--strict`**: adds the obtainable advisories (R7, clone, passthrough, tramp, subscribe, ports, ui_io, r10_aggregate, height, module_size).
- **`--super-strict`**: adds the aspirational one (R11).
- public_surface, app_share, module_avg, clone_inside, unassigned, ports_unwired and r11_share are reported at every tier and scored by none.

The score is the Elixir linter's: 100 minus weighted findings per 100 functions (weights R1/R2/R5/R9/R10 ×3,
R4 ×2, the rest ×1), with a second count of functions carrying no scored finding, and the rules-met
count, because a density lets one finding in a large codebase round away. Functions are methods plus
one per template.

A rule whose checks are all off (by `checks:`, `--disable` or a preset) is **not adopted**: the
report says so in the rules line and the JSON (`"state": "not_adopted"`), and leaves it out of the
rules-met count rather than calling it met. One check of a rule still on keeps the rule checked.

## Layout

```
bin/ala_lint                 the command
lib/ala_lint.rb              analyze(root, **opts) → Report
lib/ala_lint/parser.rb       one Ruby file → Source::Units (Prism)
lib/ala_lint/templates.rb    one ERB file → a template unit (compiled by ERB, parsed by Prism)
lib/ala_lint/model.rb        the project: units, resolution, layers, edges
lib/ala_lint/layers.rb       the declared layer map and the assignment
lib/ala_lint/rules/*.rb      one file per concern (coupling, state, literals, contracts, naming, minimality, ports, data, composition, clones)
lib/ala_lint/report.rb       scores, rules met, text and JSON
lib/ala_lint/checks.rb       the registry: check → rule, tier, weight, thresholds
lib/ala_lint/config.rb       .ala_lint.rb + CLI overrides → effective levels
test/                        Minitest, one small project per test written to a temp dir
```

The linter lints itself (`bin/ala_lint lib`, no layer map): two R5 findings (`"helpers"` is a name
`Model` and `Rules::Composition` both know, `"partial"` one `Templates` and `Rules::Composition` both
know) and advisories, among them thirteen `clone` findings, most of them the rules' shared idiom
(walk the units, skip some, flag) rather than a copied concept.
