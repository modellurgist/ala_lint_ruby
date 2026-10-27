require_relative "test_helper"

class NamingTest < Minitest::Test
  include LintHelper

  def test_role_names_and_meaningless_names_but_not_rails_helpers_or_run
    r = lint(
      "domain/cart_service.rb" => "class CartService; def x; end; end\n",
      "domain/order_manager.rb" => "class OrderManager; def process2; end; def run; end; def f1; end; end\n",
      "app/helpers/live_helper.rb" => "module LiveHelper; def row_id; end; end\n",
      "app/pages_controller.rb" => "class PagesController < ApplicationController; def show; end; end\n"
    )
    assert_finding r, :r6, /CartService is named for its role/
    assert_finding r, :r6, /OrderManager is named for its role/
    assert_finding r, :r6, /#process2: a name that teaches nothing/
    assert_finding r, :r6, /#f1/
    refute_finding r, :r6, /#run/
    refute_finding r, :r6, /LiveHelper/
    refute_finding r, :r6, /PagesController/
  end

  def test_primitive_wrappers_but_not_predicates_or_configured_rules
    r = lint(
      "domain/m.rb" => "class M\n  def add(a, b) = a + b\n  def big?(a, b) = a > b\n  def scale(n) = n * @unit\n  def apply(n) = @unit * n\nend\n"
    )
    assert_finding r, :r6, /M#add wraps the primitive \+/
    refute_finding r, :r6, /big\?/
    refute_finding r, :r6, /scale/
    refute_finding r, :r6, /apply/
  end

  def test_tramp_parameter_two_hops_but_not_one
    r = lint(
      "domain/checkout.rb" => "class Checkout\n  def pay(order, key) = Gateway.charge(order, key)\n  def once(order, key) = Rates.cost(order, key)\nend\n",
      "paradigms/gateway.rb" => "class Gateway\n  def self.charge(order, key) = Http.post(order, key)\nend\n",
      "paradigms/rates.rb" => "class Rates\n  def self.cost(order, key) = order.total * key.length\nend\n",
      "foundation/http.rb" => "class Http; def self.post(a, b) = [a, b]; end\n"
    )
    assert_finding r, :tramp, /Checkout#pay never reads order, only carries it to Gateway/
    refute_finding r, :tramp, /Checkout#once/
  end

  def test_ui_io_in_a_component_template
    r = lint(
      "app/views/components/_row.html.erb" => "<%= Product.find(1).name %>\n",
      "app/models/product.rb" => "class Product < ApplicationRecord; def x; end; end\n",
      layers: [{ name: :application, paths: [%r{\Aapp/views/pages}] }, { name: :domain, paths: [%r{\Aapp/views/components/}] }, { name: :foundation, paths: [%r{\Aapp/models/}] }]
    )
    assert_finding r, :ui_io, /_row reaches Product.find/
  end
end

class MinimalityTest < Minitest::Test
  include LintHelper

  def test_dead_privates_but_not_ones_named_by_symbol_or_elsewhere
    r = lint(
      "domain/a.rb" => "class A\n  before_action :guard\n  def go = helper(&:fmt)\n  private\n  def guard; end\n  def fmt; end\n  def unused; end\n  def shared; end\nend\n",
      "domain/b.rb" => "module B; def x = shared; end\n"
    )
    assert_finding r, :r7, /A#unused is private and never called/
    refute_finding r, :r7, /guard|fmt|shared/
  end

  def test_passthrough_over_a_constant_and_delegation_over_a_field
    r = lint(
      "domain/saver.rb" => "class Saver\n  def save(x) = Store.insert(x)\n  def push(v) = @inner.push(v)\n  def ok?(x) = Store.ok?(x)\n  def more(x) = Store.insert(x, 1)\nend\n",
      "foundation/store.rb" => "class Store; def self.insert(x, y = nil); end; def self.ok?(x); end; end\n"
    )
    assert_finding r, :passthrough, /Saver#save only renames Store.insert/
    assert_finding r, :passthrough, /Saver#push delegates to @inner.push unchanged: expected where delegation replaces inheritance/
    refute_finding r, :passthrough, /ok\?|more/
  end

  def test_module_size
    big = "class Big\n" + (1..13).map { "  def m#{_1}; end\n" }.join + "end\n"
    r = lint("domain/big.rb" => big, set: { "module_size.max" => 10 })
    assert_finding r, :module_size, /Big is 15 lines, over 10/
  end
end

class PublicSurfaceTest < Minitest::Test
  include LintHelper

  def klass(name, ports, extra = "") = "class #{name}\n" + (1..ports).map { "  def m#{_1}(x) = x.go\n" }.join + extra + "end\n"
  def peers(counts) = counts.each_with_index.to_h { |n, i| ["domain/p#{i}.rb", klass("P#{i}", n)] }

  def test_an_outlier_among_its_layer_is_reported_at_every_tier_and_never_scored
    files = peers([2, 2, 3, 3, 3, 4]).merge("domain/big.rb" => klass("Big", 14))
    %i[default strict super_strict].each do |tier|
      r = lint(files, tier: tier)
      assert_finding r, :public_surface, /Big exposes 14 public ports, above 10 \(the domain layer's Q3 3\.5 \+ 1\.5 × IQR 1\.0 = 5\.0; floor 10\)/
      refute r.scored.any? { _1.check == :public_surface }, "public_surface scored at #{tier}"
    end
    refute_finding lint(files), :public_surface, /P\d/
    assert lint(files, enforce: ["public_surface"]).scored.any? { _1.check == :public_surface }
  end

  def test_a_wide_module_among_wide_peers_is_not_an_outlier
    refute_finding lint(peers([11, 12, 12, 13, 13])), :public_surface
  end

  def test_each_layer_is_its_own_distribution
    files = peers([2, 2, 3, 3]).merge("domain/big.rb" => klass("Big", 13))
    files.merge!((0..3).to_h { ["foundation/f#{_1}.rb", klass("F#{_1}", 13 + _1)] })
    r = lint(files)
    assert_finding r, :public_surface, /Big exposes 13/
    refute_finding r, :public_surface, /F\d/
  end

  def test_the_floor_keeps_a_small_app_quiet_and_is_configurable
    files = peers([1, 1, 1, 1]).merge("domain/five.rb" => klass("Five", 5))
    refute_finding lint(files), :public_surface
    assert_finding lint(files, set: { "public_surface.floor" => 4 }), :public_surface, /Five exposes 5 public ports, above 4/
  end

  def test_a_calibration_module_is_a_table_not_ports
    calibration = <<~RB
      class Catalog
        RATES = { standard: 500, express: 1500 }.freeze
        NAMES = %w[a b].freeze
        def rate(kind) = RATES.fetch(kind)
        def rate_or_zero(kind) = RATES.fetch(kind, 0)
        def name_of(i) = NAMES[i]
        def names = NAMES
        def currency = "USD"
        def limits = { undo: 5, lines: 20 }.freeze
        def free_over = 5000
        def tiers = [ 1, 2, 3 ]
        def gift = nil
        def page_size = Foundation::Paging::SIZE
        def texts = { title: "Cart", empty: "Nothing here" }
        def code(kind) = { a: "A1", b: "B2" }[kind]
        def on? = true
        def rates = RATES
      end
    RB
    files = peers([1, 1, 1, 1]).merge("domain/catalog.rb" => calibration)
    refute_finding lint(files, set: { "public_surface.floor" => 2 }), :public_surface, /Catalog/
    computing = calibration.sub("def on? = true", "def on?(x) = x > 1")
    assert_finding lint(peers([1, 1, 1, 1]).merge("domain/catalog.rb" => computing), set: { "public_surface.floor" => 2 }), :public_surface, /Catalog exposes 14 public ports/
  end

  def test_a_shape_dispatch_counts_one_port_per_pattern
    dispatch = <<~RB
      def set_product(lines, change)
        case change
        in { stock: } then lines.stock(stock)
        in { amount: } then lines.price(amount)
        in { name: String => n } then lines.rename(n)
        end
      end
    RB
    files = peers([1, 1, 1, 1]).merge("domain/lines.rb" => klass("Lines", 2, dispatch))
    assert_finding lint(files, set: { "public_surface.floor" => 4 }), :public_surface, /Lines exposes 5 public ports/
    plain = klass("Lines", 2, "  def set_product(lines, change) = lines.set(change)\n")
    refute_finding lint(peers([1, 1, 1, 1]).merge("domain/lines.rb" => plain), set: { "public_surface.floor" => 4 }), :public_surface
  end
end

class PortsTest < Minitest::Test
  include LintHelper

  def test_duck_typing_locators_and_abstract_bases
    r = lint(
      "domain/checkout.rb" => "class Checkout\n  def pay(g) = g.respond_to?(:charge) && g.charge\n  def port(p) = p.respond_to?(:push)\n  def gw = Rails.configuration.x.gateway\n  def env = ENV[\"KEY\"]\n  def di = Import[\"payments.gateway\"]\nend\n",
      "domain/stripe.rb" => "class Stripe < Gateway; def charge; end; end\n",
      "paradigms/data_flow.rb" => "module DataFlow; def push(v); end; end\n",
      "foundation/gateway.rb" => "class Gateway; def charge = raise(NotImplementedError); end\n",
      "app/screen.rb" => "class Screen; def gw = Rails.configuration.x.gateway; end\n"
    )
    assert_finding r, :r9, /respond_to\?\(:charge\) on a collaborator: duck typing/
    refute_finding r, :r9, /respond_to\?\(:push\)/
    assert_finding r, :r9, /Checkout#gw uses Rails.configuration: global configuration/
    assert_finding r, :r9, /ENV\.\[\]: an environment lookup/
    assert_finding r, :r9, /Import\.\[\]: a dependency-injection container/
    assert_finding r, :r9, /Stripe extends Gateway, an abstract base class/
    refute_finding r, :r9, /Screen/
  end

  def test_type_tests_only_against_a_paradigm_or_the_foundation
    r = lint(
      "domain/drawing.rb" => "class Drawing\n  def peer?(p) = p.is_a?(Stripe)\n  def port?(p) = p.kind_of?(DataFlow)\n  def money?(v) = v.is_a?(Gateway)\n  def hash?(v) = v.is_a?(Hash)\nend\n",
      "domain/stripe.rb" => "class Stripe; def charge; end; end\n",
      "paradigms/data_flow.rb" => "module DataFlow; def push(v); end; end\n",
      "foundation/gateway.rb" => "class Gateway; def charge; end; end\n"
    )
    assert_finding r, :r9, /Drawing#peer\? checks is_a\?\(Stripe\) on a collaborator/
    refute_finding r, :r9, /DataFlow|Gateway|Hash/
  end

  def test_header_comment_ports_and_unwired_outputs
    r = lint(
      "domain/wish.rb" => "# Keeps product ids. Ports out: added. Config: none.\nclass Wish\n  output :added, DataFlow\n  output :removed, DataFlow\n  input(:add, DataFlow) { }\nend\n",
      "app/screen.rb" => "class Screen\n  def initialize = @w.wire_to(x, from: :added)\nend\n",
      "paradigms/data_flow.rb" => "module DataFlow; end\n"
    )
    assert_finding r, :ports, /Wish declares ports its header comment doesn't list \(removed, add\)/
    assert_finding r, :ports_unwired, /Wish output :removed is named by no composition/
    refute_finding r, :ports_unwired, /:added/
  end

  def live(feed_header) = <<~RUBY
    # Outside change as a paradigm.
    module Live
      def self.read(fact) = fact

      # Config: topic. In: push.
      class Publish
        input(:push, DataFlow) { }
      end

      #{feed_header}
      class Feed
        input(:receive, DataFlow) { }
        output :changed, DataFlow
      end
    end
  RUBY

  def test_nested_class_ports_are_documented_by_the_nested_class_header
    r = lint("paradigms/live.rb" => live("# In: receive. Out: changed."), "paradigms/data_flow.rb" => "module DataFlow; end\n")
    refute_finding r, :ports
  end

  def test_a_nested_class_missing_its_ports_is_blamed_at_its_own_line
    r = lint("paradigms/live.rb" => live("# The page's subscription."), "paradigms/data_flow.rb" => "module DataFlow; end\n")
    assert_equal [["Live::Feed declares ports its header comment doesn't list (changed, receive)", 11]],
                 findings(r, :ports).map { [_1.message.split(": a reader").first, _1.line] }
  end

  def test_a_module_is_still_blamed_for_ports_it_declares_itself
    src = "# Outside change.\nmodule Live\n  input(:tick, DataFlow) { }\n\n  # In: push.\n  class Publish\n    input(:push, DataFlow) { }\n  end\nend\n"
    r = lint("paradigms/live.rb" => src, "paradigms/data_flow.rb" => "module DataFlow; end\n")
    assert_equal [["Live declares ports its header comment doesn't list (tick)", 2]],
                 findings(r, :ports).map { [_1.message.split(": a reader").first, _1.line] }
  end
end
