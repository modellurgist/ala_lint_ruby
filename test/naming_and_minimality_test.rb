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

  def test_module_size_public_surface_and_average
    big = "class Big\n" + (1..13).map { "  def m#{_1}; end\n" }.join + "end\n"
    r = lint("domain/big.rb" => big, "domain/small.rb" => "class Small; def x; end; end\n")
    assert_finding r, :public_surface, /Big exposes 13 public methods \(max 12\)/
    refute r.scored.any? { _1.check == :public_surface }
    assert lint({ "domain/big.rb" => big }, tier: :super_strict).scored.any? { _1.check == :public_surface }
    refute lint({ "domain/big.rb" => big }, tier: :strict).scored.any? { _1.check == :public_surface }
    r = lint("domain/big.rb" => big, set: { "module_size.max" => 10 })
    assert_finding r, :module_size, /Big is 15 lines, over 10/
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
end
