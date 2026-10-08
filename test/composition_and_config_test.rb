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
        @w.on(:x) { |v| v > 1 ? a : b }
        Totals.new(@cart.lines)
      end
      def rule
        if @cart.empty? then flash[:x] = "Empty"; redirect_to cart_path else redirect_to checkout_path end
      end
    end
  RB

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
    assert_finding r, :r11, /#total branches \(if\) \(inside a wiring block\)/
    assert_finding r, :r11, /#rule branches \(if\)/
    assert_finding r, :r11_share, /composition functions hold logic/
    refute r.scored.any? { _1.check == :r11 }
    assert lint({ "app/carts_controller.rb" => CONTROLLER }, tier: :super_strict).scored.any? { _1.check == :r11 }
    refute lint({ "app/carts_controller.rb" => CONTROLLER }, tier: :strict).scored.any? { _1.check == :r11 }
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
