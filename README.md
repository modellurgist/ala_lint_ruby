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
bin/ala_lint --root app --super-strict      # and the aspirational ones (R11, public_surface)
bin/ala_lint --root app --min-score 80      # exit 1 below 80 (the CI gate)
bin/ala_lint --root app --require-layers    # exit 1 if any unit matches no layer
bin/ala_lint --root app --enforce r7        # promote one check to scored
bin/ala_lint --root app --disable r3        # turn one off (the report says so)
bin/ala_lint --root app --set height.max=4  # retune a threshold
bin/ala_lint --root app --format json
bin/ala_lint --list-checks                  # every check, its tier and threshold
bin/ala_lint --help                         # unknown flags fail with the usage, never silently
rake test                                   # the linter's own suite (Minitest)
```

Ruby 4.0 (Prism ships with it); `.tool-versions` pins 4.0.7 for asdf.

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
  identity_models: %w[Cart],        # belongs_to these is sharing an identity key, not data (R10)
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
| **r4** | a composition-layer class assigning a field outside `initialize` and outside a wiring block (a controller handing the view a constant, a parameter, a literal or a landed value is exempt; memoising a `new` is exempt); a domain class exposing a collection it mutates through `attr_reader`; `Mutex`/`Monitor` in a domain class; `instance_variable_get/set` on another object | exact on shape |
| **r5** | the same identifier-like string in two units unless both are the composition (render paths, `class:`/`data:` values, string-method arguments and a few MIME/HTTP words skipped; a template's `id=`, `name=`, `data-controller=` values count); a `$2.99` label whose cents are an integer literal somewhere; `send`/`public_send` with a name built from a string | heuristic: textual duplication, not semantic agreement |
| **r6** | role names (`*Service`, `*Manager`, `*Helper` outside `app/helpers`, `*Handler`, `*Utils`), meaningless method names (`f1`, `process2`, `tmp`, single letters), a public method that is one operator over its parameters (a predicate, or a method over its own configured field, is spared) | weak heuristic; naming is judgement |
| **r9** | a peer module included as an interface; subclassing an abstract base (`raise NotImplementedError`); `respond_to?(:x)` on a collaborator where `x` isn't a paradigm's message; `Rails.configuration`, `Rails.application`, `ENV`, `Import[]`, `Dry::Container` below the composition | exact on these forms; whether outputs announce is judgement |
| **r10** | a record or value type read by two units of one peer-forbidden layer (constructing one isn't reading it); `has_many`/`has_one`; `belongs_to` a model not listed under `identity_models` | heuristic on associations |
| **layer** | an `@ala_layer` tag naming no declared layer | exact |
| **r7** (advisory) | a private method named nowhere in the project (calls, symbols, `&:name`; a dynamic `send` anywhere turns it off) | exact on names |
| **passthrough** (advisory) | a public method whose body only renames another unit's method with the same arguments; delegation over a field is reported as the §7.16 shape | heuristic |
| **tramp** (advisory) | a public parameter never read, only passed bare to another unit's method that passes it on again (R6's "should") | heuristic; only const-receiver calls resolve |
| **subscribe** (advisory) | below the composition and above the bottom: `subscribe`, `turbo_stream_from`, `broadcast_*_to` with a literal topic | exact |
| **ports** (advisory) | a class with `output`/`input` ports its header comment doesn't name (§5.8.2) | exact; the port macros are this edition's Foundation |
| **ui_io** (advisory) | a template below the composition calling a record model or a store method | heuristic |
| **r10_aggregate** (advisory) | a lower-layer type read by two units of a peer-forbidden layer above it; a `Data`/`Struct` type that defines behaviour of its own (a `Money` with `+`) is an abstraction both ends depend on and is exempt, a bare field bag is a DTO and prompts | prompt |
| **height**, **module_size**, **public_surface**, **module_avg**, **app_share** | thresholds (5 hops between units, 500 lines, 12 public methods, 100-line average, 20% of functions) | metrics |
| **r11** (aspirational) | in composition units: branches (a branch whose arms only redirect, render or hand the view a constant, parameter, literal or landed value is routing and exempt), arithmetic, iteration with a block, one lower call's result bound and handed to another or passed straight in (`new`, wiring calls, `params`/`session`/`flash` and rendering exempt); in composition templates: branches, comparisons, arithmetic, loops, calls into lower units | heuristic; which departures the framework forces is judgement |
| **ports_unwired**, **r11_share**, **unassigned** | report-only prompts | — |
| **r8** | not checked: judgement | — |

Not read: JavaScript (Stimulus controllers), so a contract between a template's `data-action` and
a controller's method is a human's to check; and SQL, migrations and schema.

## Tiers and scores

- **default**: the required checks score (R1, R2, R3, R4, R5, R6, R9, R10, layer validity).
- **`--strict`**: adds the obtainable advisories (R7, passthrough, tramp, subscribe, ports, ui_io, r10_aggregate, height, module_size).
- **`--super-strict`**: adds the aspirational ones (R11, public_surface).
- app_share, module_avg, unassigned, ports_unwired and r11_share are reported at every tier and scored by none.

The score is the Elixir linter's: 100 minus weighted findings per 100 functions (weights R1/R2/R5/R9/R10 ×3,
R4 ×2, the rest ×1), with a second count of functions carrying no scored finding, and the rules-met
count, because a density lets one finding in a large codebase round away. Functions are methods plus
one per template.

## Layout

```
bin/ala_lint                 the command
lib/ala_lint.rb              analyze(root, **opts) → Report
lib/ala_lint/parser.rb       one Ruby file → Source::Units (Prism)
lib/ala_lint/templates.rb    one ERB file → a template unit (compiled by ERB, parsed by Prism)
lib/ala_lint/model.rb        the project: units, resolution, layers, edges
lib/ala_lint/layers.rb       the declared layer map and the assignment
lib/ala_lint/rules/*.rb      one file per concern (coupling, state, literals, contracts, naming, minimality, ports, data, composition)
lib/ala_lint/report.rb       scores, rules met, text and JSON
lib/ala_lint/checks.rb       the registry: check → rule, tier, weight, thresholds
lib/ala_lint/config.rb       .ala_lint.rb + CLI overrides → effective levels
test/                        Minitest, one small project per test written to a temp dir
```

The linter lints itself (`bin/ala_lint lib`, no layer map): one R5 finding (`"helpers"` is a name
`Model` and `Rules::Composition` both know) and a few advisories.
