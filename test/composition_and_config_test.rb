require_relative "test_helper"

class CompositionTest < Minitest::Test
  include LintHelper

  CONTROLLER = <<~RB
    class CartsController < ApplicationController
      def destroy
        screen.input_port(:remove).push(params[:id].to_i)
        if screen.saved then redirect_to cart_path else render :show end
      end
      def show
        return redirect_to cart_success_path if screen.step == :complete
        @s = screen
      end
      def saved_or_form(path, title)
        if screen.saved then redirect_to path else @form = screen.form; @title = title; render :again end
      end
      def total
        lines = @cart.lines
        @sum = Pricing.sum(lines) + 5
        @cart.lines.each { }
        @totals.price(@cart.lines)
        @sink = Patch.new(target: Names.summary_id)
        @w.on(:x) { |v| v > 1 ? a : b }
        Totals.new(@cart.lines)
      end
      def rule
        if @cart.empty? then flash[:x] = "Empty"; redirect_to cart_path else redirect_to checkout_path end
      end
    end
  RB

  def test_logic_in_a_lambda_a_constant_holds_is_the_constants
    src = <<~RB
      class PortalController < ApplicationController
        VOLUME_TIER = ->(subtotal) { subtotal > 100 ? 5 : 0 }
        RATES = { flat: ->(n) { n * 2 } }.freeze
        EACH = ->(lines) { lines.each { } }
        VIEWS = { lines: ->(s) { s }, review: "portals/review" }.freeze
        def show = (@totals = Totals.new(volume: VOLUME_TIER))
      end
    RB
    r = lint("app/portal_controller.rb" => src, "domain/totals.rb" => "class Totals; def initialize(volume:); end; end\n")
    assert_finding r, :r11, /PortalController::VOLUME_TIER branches \(if\)/
    assert_finding r, :r11, /PortalController::RATES computes \(\*\)/
    assert_finding r, :r11, /PortalController::EACH iterates \(each\)/
    refute_finding r, :r11, /VIEWS/
    refute_finding r, :r11, /#show/
    assert_finding r, :r11_share, /3 of 5 composition functions/
  end

  def test_logic_kinds_and_the_routing_exemption
    r = lint("app/carts_controller.rb" => CONTROLLER, "domain/pricing.rb" => "class Pricing; def self.sum(l); end; end\n", "domain/totals.rb" => "class Totals; def initialize(l); end; end\n")
    refute_finding r, :r11, /#destroy branches/
    refute_finding r, :r11, /#show/
    refute_finding r, :r11, /#saved_or_form/
    refute_finding r, :r11, /#destroy.*hands|#destroy.*passes/
    assert_finding r, :r11, /#total hands lines \(one abstraction's result\) to sum/
    assert_finding r, :r11, /#total computes \(\+\)/
    assert_finding r, :r11, /#total iterates \(each\)/
    assert_finding r, :r11, /#total passes @cart.lines straight into price/
    refute_finding r, :r11, /straight into new/
    refute_finding r, :r11, /Names.summary_id/
    assert_finding r, :r11, /#total branches \(if\) \(inside a wiring block\)/
    assert_finding r, :r11, /#rule branches \(if\)/
    assert_finding r, :r11_share, /composition functions hold logic/
    refute r.scored.any? { _1.check == :r11 }
    assert lint({ "app/carts_controller.rb" => CONTROLLER }, tier: :super_strict).scored.any? { _1.check == :r11 }
    refute lint({ "app/carts_controller.rb" => CONTROLLER }, tier: :strict).scored.any? { _1.check == :r11 }
  end

  def test_a_dynamic_constant_path_still_lints_its_file
    src = "class Drawing\n  def edges(part) = self.class::GROUNDED.map { \"  outside -- request --> \#{part}\" }\nend\n"
    assert_finding lint("paradigms/drawing.rb" => src), :r3, /sentence built by interpolation/
  end

  def test_template_logic_in_the_composition_only
    tpl = "<% if @s.rows.any? %><% @s.rows.each do |r| %><%= r[:q] + 1 %><% end %><% end %>\n<%= @s.ids.include?(1) %>\n<%= Product.count %>\n"
    layers = [{ name: :application, paths: [%r{\Aapp/views/pages/}] }, { name: :domain, paths: [%r{\Aapp/views/components/}] }, { name: :foundation, paths: [%r{\Aapp/models/}] }]
    r = lint({ "app/views/pages/show.html.erb" => tpl, "app/views/components/_row.html.erb" => tpl, "app/models/product.rb" => "class Product < ApplicationRecord; def x; end; end\n" }, layers: layers)
    assert_finding r, :r11, /pages\/show branches \(if\) in an application template/
    assert_finding r, :r11, /pages\/show iterates \(each\)/
    assert_finding r, :r11, /pages\/show computes \(\+\)/
    assert_finding r, :r11, /pages\/show compares \(include\?\)/
    assert_finding r, :r11, /pages\/show calls Product.count, a unit below the composition/
    refute_finding r, :r11, /components\/_row/
    assert_finding r, :ui_io, /components\/_row reaches Product.count/
  end

  def test_app_share_is_reported_and_never_scored
    r = lint("app/a.rb" => "class A; def x; end; def y; end; end\n", "domain/b.rb" => "class B; def x; end; end\n")
    assert_finding r, :app_share, /composition layers hold 67% of all functions/
    refute r.scored.any? { _1.check == :app_share }
    assert lint({ "app/a.rb" => "class A; def x; end; def y; end; end\n", "domain/b.rb" => "class B; def x; end; end\n" }, tier: :super_strict).advisory.any? { _1.check == :app_share }
  end
end

class RoutingAndRunTimeNamesTest < Minitest::Test
  include LintHelper

  def controller(body, consts = "") = { "app/portal_controller.rb" => "class PortalController < ApplicationController\n#{consts}#{body}\nend\n" }

  def test_a_case_in_on_a_step_whose_arms_only_render_or_redirect_is_routing
    body = <<~RB
      def show
        case @step
        in :cart then render :cart
        in :pay then render partial: "portal/pay"
        in { done: true } then redirect_to orders_path
        end
      end
      def other
        case @step
        when :cart then render "portal/cart"
        else redirect_to root_path
        end
      end
    RB
    refute_finding lint(controller(body)), :r11
    logic = body.sub("in :pay then render partial: \"portal/pay\"", "in :pay then @total = @a + 1")
    assert_finding lint(controller(logic)), :r11, /PortalController#show branches \(casematch\)/
  end

  def test_a_literal_table_picking_what_to_render_or_run_is_routing
    consts = "  VIEWS = { cart: \"portal/cart\", pay: \"portal/pay\" }.freeze\n  HANDLERS = { cart: :show_cart, pay: :show_pay }.freeze\n"
    body = <<~RB
      def show = render VIEWS.fetch(@step)
      def part = render partial: VIEWS[@step], locals: { s: @s }
      def handle(step) = send(HANDLERS.fetch(step))
      def local
        view = VIEWS.fetch(@step)
        render view
      end
      def inline = render({ a: "portal/a", b: "portal/b" }.fetch(@step))
    RB
    refute_finding lint(controller(body, consts)), :r11
  end

  def test_a_template_or_method_name_built_at_run_time_is_a_branch
    body = <<~RB
      def a = render "portal_pricing/\#{@step}"
      def b = render partial: "portal/\#{@step}"
      def c(step) = render partial: step
      def d = render template: "portal/" + @step.to_s
      def e
        name = "portal/\#{@step}"
        render name
      end
      def f(name) = send(name)
      def g = public_send(@action)
      def h(name) = method(name).call
      def i(kind) = Object.const_get(kind).new
      def j(kind) = "Steps::\#{kind}".constantize
      def k(kind) = kind.safe_constantize
    RB
    r = lint(controller(body))
    %w[a b c d e f g h i j k].each { assert_finding r, :r11, /PortalController##{_1} chooses what runs by a name built at run time/ }
    refute r.scored.any? { _1.check == :r11 }
  end

  def test_literal_names_and_rendered_objects_stay_fine
    body = <<~RB
      def a = render "portal/cart"
      def b = render partial: "portal/pay", locals: { x: @x }
      def c = send(:show_cart)
      def d = method(:show_cart)
      def e = "Steps::Cart".constantize
      def f = render @products
      def g = render Components::Row.new(@row)
      def h = render :show
      def i = Object.const_get(:Cart)
      def j = render "elements/notice", action: @t[:undo], layout: @l
      def k = Rails.configuration.x.payment_gateway.constantize
      def l = Rails.application.config.x.gateway.safe_constantize
      def m = ENV.fetch("GATEWAY").constantize
    RB
    refute_finding lint(controller(body)), :r11
  end

  def test_a_template_case_whose_arms_only_render_is_routing
    layers = [{ name: :application, paths: [%r{\Aapp/views/pages/}] }, { name: :domain, paths: [%r{\Adomain/}] }]
    routing = "<% case @step -%>\n<% when :lines -%>\n  <%= render \"portal/lines\" %>\n<% when :review -%>\n  <%= render \"portal/review\" %>\n<% end -%>\n"
    logic = "<% case @step -%>\n<% when :lines -%>\n  <%= @total %>\n<% when :review -%>\n  <%= render \"portal/review\" %>\n<% end -%>\n"
    refute_finding lint({ "app/views/pages/routed.html.erb" => routing }, layers: layers), :r11, /branches/
    assert_finding lint({ "app/views/pages/mixed.html.erb" => logic }, layers: layers), :r11, /mixed branches/
  end

  def test_run_time_names_in_a_composition_template_but_not_below
    layers = [{ name: :application, paths: [%r{\Aapp/views/pages/}] }, { name: :domain, paths: [%r{\Aapp/views/components/}, %r{\Adomain/}] }]
    tpl = "<%= render \"portal_pricing/\#{step}\" %>\n<%= render \"portal_pricing/cart\" %>\n"
    r = lint({ "app/views/pages/show.html.erb" => tpl, "app/views/components/_row.html.erb" => tpl, "domain/lines.rb" => "class Lines; def go(n) = send(n); end\n" }, layers: layers)
    assert_finding r, :r11, /app\/views\/pages\/show chooses what runs by a name built at run time/
    assert_equal 1, findings(r, :r11).count { _1.message.include?("name built at run time") }
    refute_finding r, :r11, /components|Lines/
  end
end

class ConfigAndReportTest < Minitest::Test
  include LintHelper

  FILES = { "domain/a.rb" => "class A\n  def rate = 599\n  private\n  def dead; end\nend\n" }.freeze

  def test_score_grade_and_rules_met
    r = lint(FILES)
    assert_equal 2, r.functions
    assert_equal 1, r.weighted
    assert_equal 50, r.score
    assert_equal "D", r.grade
    assert_equal :not_met, r.rules[:r3][:state]
    assert_equal :met, r.rules[:r7][:state]
    assert_equal 1, r.rules[:r7][:advisory]
    assert_equal :unchecked, r.rules[:r8][:state]
  end

  def test_enforce_disable_and_the_checks_map
    assert lint(FILES, enforce: [:r7]).scored.any? { _1.check == :r7 }
    assert_empty findings(lint(FILES, disable: [:r3]), :r3)
    assert lint(FILES, config: { checks: { r7: :scored } }).scored.any? { _1.check == :r7 }
    r = lint(FILES, config: { checks: { r3: :advisory } })
    refute r.scored.any? { _1.check == :r3 }
    assert_includes r.model.config.params[:downgraded], :r3
    assert_includes r.to_text, "downgraded to advisory: r3"
  end

  def test_min_score_and_require_layers_gate
    assert lint(FILES, min_score: 40).passes_min_score?
    refute lint(FILES, min_score: 60).passes_min_score?
    refute lint(FILES.merge("x/b.rb" => "class B; def y; end; end\n"), require_layers: true).requires_layers_ok?
  end

  def test_text_and_json_output
    r = lint(FILES)
    assert_includes r.to_text, "[r3] domain/a.rb:2  literal 599"
    assert_includes r.to_text, "Advisory (reported, NOT scored at this tier)"
    json = JSON.parse(r.to_json)
    assert_equal 50, json["score"]
    assert_equal "r3", json["findings"].first["check"]
    assert json["findings"].first["scored"]
  end

  def test_cli_help_list_and_unknown_flags
    out = StringIO.new
    assert_equal 0, AlaLint::CLI.run(%w[--help], out: out)
    assert_includes out.string, "--super-strict"
    out = StringIO.new
    assert_equal 0, AlaLint::CLI.run(%w[--list-checks], out: out)
    assert_includes out.string, "ASPIRATIONAL"
    err = StringIO.new
    assert_equal 2, AlaLint::CLI.run(%w[--bogus], out: StringIO.new, err: err)
    assert_includes err.string, "invalid option: --bogus"
    err = StringIO.new
    assert_equal 2, AlaLint::CLI.run(%w[--enforce nope], out: StringIO.new, err: err)
    assert_includes err.string, "unknown check nope"
  end

  def test_cli_runs_a_project_and_gates
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "domain"))
      File.write(File.join(dir, "domain/a.rb"), FILES.values.first)
      File.write(File.join(dir, ".ala_lint.rb"), "{ layers: #{LintHelper::LAYERS.inspect}, paths: %w[domain] }")
      out = StringIO.new
      assert_equal 0, AlaLint::CLI.run(["--root", dir], out: out)
      assert_includes out.string, "Degree of function compliance: 50/100"
      assert_equal 1, AlaLint::CLI.run(["--root", dir, "--min-score", "90"], out: StringIO.new)
      out = StringIO.new
      assert_equal 0, AlaLint::CLI.run(["--root", dir, "--format", "json"], out: out)
      assert_equal 50, JSON.parse(out.string)["score"]
    end
  end
end

class AcceptanceTest < Minitest::Test
  include LintHelper

  SRC = "class Badge\n  # ala:accept r3 -- retail's own word, kept (checklist R3, domain vocabulary)\n  def label = \"Out of stock\"\n  def other = \"Low stock today\"\n  # ala:accept r3,r6 lines=2\n  def f1 = 42\n  def f2 = 43\n  # ala:accept r5 -- nothing here fires r5\n  def quiet = 1\nend\n"

  def test_accepted_findings_leave_the_score_and_are_listed
    r = lint("domain/badge.rb" => SRC)
    assert_equal 5, r.accepted.size
    assert_equal 1, findings(r, :r3).size
    assert_match(/Low stock today/, messages(r, :r3).first)
    assert_equal 3, r.acceptances.size
    assert_equal 1, r.unused_acceptances.size
    assert_includes r.to_text, "Accepted by hand: 5 finding(s) under 3 ala:accept comment(s), 1 covering nothing"
    listing = r.accepted_listing
    assert_includes listing, "domain/badge.rb:2  r3  lines 3  -- retail's own word"
    assert_includes listing, "↳ [r3] line 3"
    assert_includes listing, "domain/badge.rb:5  r3,r6  lines 6–7"
    assert_includes listing, "covers nothing"
    assert_equal 5, JSON.parse(r.to_json)["accepted"].size
  end

  def test_an_erb_acceptance_and_an_unknown_check
    r = lint(
      "app/views/pages/show.html.erb" => "<%# ala:accept r11 -- the one loop this page keeps %>\n<% rows.each do |r| %><%= r %><% end %>\n",
      layers: [{ name: :application, paths: [%r{\Aapp/views/}] }]
    )
    assert_equal 1, r.accepted.size
    assert_empty findings(r, :r11)
    err = assert_raises(ArgumentError) { lint("domain/a.rb" => "# ala:accept nope\nclass A; def x = 5; end\n") }
    assert_match(/a\.rb:1: ala:accept names no such check: nope/, err.message)
  end

  def test_list_accepted_from_the_cli
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "domain"))
      File.write(File.join(dir, "domain/badge.rb"), SRC)
      File.write(File.join(dir, ".ala_lint.rb"), "{ layers: #{LintHelper::LAYERS.inspect}, paths: %w[domain] }")
      out = StringIO.new
      assert_equal 0, AlaLint::CLI.run(["--root", dir, "--list-accepted"], out: out)
      assert_includes out.string, "Accepted by hand (5 finding(s) under 3 comment(s))"
    end
  end
end

class PlainWiringTest < Minitest::Test
  include LintHelper

  PLAIN = {
    "app/screen.rb" => <<~RB,
      module Screens
        class Cart
          include ProgrammingParadigms::Wiring
          GROUNDED = [].freeze
          attr_reader :rows, :summary
          def load = run(:lines, @lines.load(@items.lookup))
          def bump(change) = run(:lines, @lines.bump(change))
          def initialize = (@lines, @items, @totals = Domain::Lines.new, Domain::Items.new, Domain::Totals.new)

          private

          def wire(part, output, payload)
            case [ part, output ]
            in [ :lines, :changed ] then run(:items, @items.apply(payload))
            in [ :lines, :rows ] then @rows = payload
            in [ :lines, :contents ] then run(:totals, @totals.contents(payload))
            in [ :totals, :summary ] then @summary = payload
            end
          end
        end
      end
    RB
    "domain/lines.rb" => "module Domain; class Lines; OUTPUTS = %i[changed rows contents].freeze; def load(items) = {}; def bump(c) = {}; end; end\n",
    "domain/items.rb" => "module Domain; class Items; def lookup = []; def apply(c) = nil; end; end\n",
    "domain/totals.rb" => "module Domain; class Totals; OUTPUTS = %i[summary].freeze; def contents(c) = {}; end; end\n",
    "paradigms/wiring.rb" => "module ProgrammingParadigms; module Wiring; def run(part, outputs) = outputs&.each { |o, p| wire(part, o, p) }; end; end\n"
  }.freeze

  def test_a_wiring_table_lands_outputs_and_runs_parts_without_findings
    report = lint(PLAIN)
    refute_finding report, :r4, /assigns/
    refute_finding report, :r11, /branches|passes|hands/
  end

  def test_a_handoff_outside_run_is_still_handled_data
    files = PLAIN.merge("app/other.rb" => "module Screens; class Other; def go = @lines.load(@items.lookup); def initialize = (@lines, @items = Domain::Lines.new, Domain::Items.new); end; end\n")
    report = lint(files)
    assert_finding report, :r11, /go passes @items.lookup straight into load/
  end

  CALLED = PLAIN.merge(
    "app/shop.rb" => <<~RB,
      module Screens
        class Shop
          include ProgrammingParadigms::Wiring
          def parts = { lines: @lines }
          def initialize = (@lines, @items, @totals, @flow = Domain::Lines.new, Domain::Items.new, Domain::Totals.new, Domain::Flow.new)
          def contents(c) = run(:totals, @totals.contents(c))
          def go
            @lines.load(@items.lookup)
            @totals.contents(@items.lookup)
            @flow.check(@items.lookup)
            found = @items.lookup
            @flow.review(found)
            ready = @flow.ready?(found)
            run(:lines, @lines.bump(found)) if ready
          end
        end
      end
    RB
    "domain/flow.rb" => "module Domain; class Flow; def check(l) = nil; def review(l) = nil; def ready?(l) = true; end; end\n"
  ).freeze

  def test_by_default_hand_offs_into_wired_and_called_parts_are_both_handled_data
    report = lint(CALLED)
    assert_finding report, :r11, /Shop#go passes @items.lookup straight into load/
    assert_finding report, :r11, /Shop#go passes @items.lookup straight into contents/
    assert_finding report, :r11, /Shop#go passes @items.lookup straight into check/
    assert_finding report, :r11, /Shop#go hands found .* to review/
    assert_finding report, :r11, /Shop#go hands found .* to ready\?/
    assert_finding report, :r11, /Shop#go branches \(if\)/
  end

  def test_wired_only_leaves_out_hand_offs_into_a_called_part
    report = lint(CALLED, config: { checks: { r11: { calls: :wired_only } } })
    assert_finding report, :r11, /Shop#go passes @items.lookup straight into load/
    assert_finding report, :r11, /Shop#go passes @items.lookup straight into contents/
    refute_finding report, :r11, /straight into check|to review|to ready\?/
    assert_finding report, :r11, /Shop#go branches \(if\)/
  end

  def test_wired_only_from_the_cli_and_a_bad_value_fails
    Dir.mktmpdir do |dir|
      CALLED.each { |path, src| FileUtils.mkdir_p(File.dirname(File.join(dir, path))); File.write(File.join(dir, path), src) }
      File.write(File.join(dir, ".ala_lint.rb"), "{ layers: #{LintHelper::LAYERS.inspect}, paths: %w[app domain paradigms] }")
      out = StringIO.new
      AlaLint::CLI.run(["--root", dir, "--set", "r11.calls=wired_only"], out: out)
      assert_includes out.string, "straight into contents"
      refute_includes out.string, "straight into check"
      err = StringIO.new
      assert_equal 2, AlaLint::CLI.run(["--root", dir, "--set", "r11.calls=some"], out: StringIO.new, err: err)
      assert_includes err.string, "r11.calls must be one of all, wired_only"
    end
    assert_raises(ArgumentError) { lint(CALLED, config: { checks: { r11: { calls: :wired } } }) }
  end

  def test_alternated_and_wildcard_wires_are_still_a_wiring_table
    screen = PLAIN.fetch("app/screen.rb")
      .sub("in [ :lines, :rows ] then @rows = payload\n", "in [ :lines, :rows ] | [ :totals, :rows ] then @rows = payload\n")
      .sub("in [ :totals, :summary ] then @summary = payload\n", "in [ :totals, _ ] then @summary = payload\n")
    refute_equal PLAIN.fetch("app/screen.rb"), screen
    report = lint(PLAIN.merge("app/screen.rb" => screen))
    refute_finding report, :r4, /assigns/
    refute_finding report, :r11, /branches|passes|hands/
  end

  def test_an_alternation_that_binds_or_matches_values_is_not_a_wire
    screen = PLAIN.fetch("app/screen.rb").sub("in [ :totals, :summary ] then @summary = payload\n",
                                                 "in [ :totals, :summary ] | [ :totals, 1 ] then @summary = payload\n")
    assert_finding lint(PLAIN.merge("app/screen.rb" => screen)), :r11, /branches/
  end

  def test_a_case_in_any_other_method_is_still_a_branch
    files = PLAIN.merge("app/other.rb" => "module Screens; class Other; def pick(x) = (case [ x, :a ] in [ 1, :a ] then 1 in [ 2, :a ] then 2 end); end; end\n")
    report = lint(files)
    assert_finding report, :r11, /pick branches/
  end
end

class PlainFeatureTest < Minitest::Test
  include LintHelper

  def test_a_feature_that_collects_and_sends_out_is_wiring
    files = PlainWiringTest::PLAIN.merge("app/feature.rb" => <<~RB)
      module Features
        class Order
          include ProgrammingParadigms::Wiring
          GROUNDED = [].freeze
          def bump(change) = collect { run(:lines, @lines.bump(change)) }
          def initialize = (@lines, @undo = Domain::Lines.new, Domain::Lines.new)

          private

          def wire(part, output, payload)
            case [ part, output ]
            in [ :lines, :removed ] then run(:undo, @undo.bump(payload))
            in [ :lines, _ ] then out(output, payload)
            end
          end
        end
      end
    RB
    report = lint(files, layers: [{ name: :application, paths: [%r{\Aapp/screen}] }, { name: :features, paths: [%r{\Aapp/feature}] }] + LintHelper::LAYERS.drop(1))
    refute_finding report, :r11, /Order/
    refute_finding report, :r4, /Order/
  end

  def test_a_message_the_paradigm_declares_is_not_counted_on_the_public_surface
    methods = (1..10).map { "def m#{_1}(x) = x.go" }.join("\n")
    files = { "domain/wide.rb" => "module Domain; class Wide\n#{methods}\ndef parts = {}\nend; end\n" }
    files.merge!((1..4).to_h { ["domain/n#{_1}.rb", "class N#{_1}; def go(x) = x.go; end\n"] })
    assert_finding lint(files, super_strict: true), :public_surface, /Wide exposes 11 public ports/
    declared = files.merge("paradigms/wiring.rb" => "module Wiring\n  def parts = {}\n\n  private\n\n  def run(part) = part\nend\n")
    refute_finding lint(declared, super_strict: true), :public_surface, /Wide/
  end
end
