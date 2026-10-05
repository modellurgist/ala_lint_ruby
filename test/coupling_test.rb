require_relative "test_helper"

class CouplingTest < Minitest::Test
  include LintHelper

  def test_upward_peer_and_dropping_edges_with_a_layer_map
    r = lint(
      "app/page.rb" => "class Page\n  def go = Wish.new.run\nend\n",
      "domain/wish.rb" => "class Wish\n  def run = Cart.help\n  def bad = Page.new\n  def ok = Calc.call(1)\nend\n",
      "domain/cart.rb" => "class Cart\n  def self.help = 1\nend\n",
      "paradigms/calc.rb" => "class Calc\n  def self.call(x) = x\nend\n"
    )
    assert_finding r, :r1, /Wish#run calls Cart: cross-peer/
    assert_finding r, :r1, /Wish#bad instantiates Page .*flows UP/
    refute_finding r, :r1, /Calc/
    refute_finding r, :r1, /Page#go/
  end

  def test_every_edge_kind_the_oo_checklist_lists
    r = lint(
      "domain/a.rb" => "class A < B\n  include C\n  def x = D::K\nend\n",
      "domain/b.rb" => "class B; def y; end; end\n",
      "domain/c.rb" => "module C; def z; end; end\n",
      "domain/d.rb" => "class D; K = 1; end\n"
    )
    assert_finding r, :r1, /A subclasses B: cross-peer.*inheritance edge/
    assert_finding r, :r1, /A includes C: cross-peer/
    assert_finding r, :r1, /A#x references D: cross-peer/
    assert_finding r, :r9, /A includes C, a peer.*owned interface/
  end

  def test_subclassing_your_own_lower_class_is_an_edge_but_a_framework_base_is_not
    r = lint(
      "domain/truck.rb" => "class Truck < Vehicle; def x; end; end\n",
      "foundation/vehicle.rb" => "class Vehicle; def drive; end; end\n",
      "foundation/rec.rb" => "class Rec < ApplicationRecord; def x; end; end\n"
    )
    assert_finding r, :r1, /Truck subclasses Vehicle: a subclass of your own class/
    refute_finding r, :r1, /Rec/
  end

  def test_a_model_callback_reaching_another_unit_is_r1
    r = lint(
      "foundation/order.rb" => "class Order < ApplicationRecord\n  after_commit { Mailer.ping }\nend\n",
      "foundation/mailer.rb" => "class Mailer; def self.ping; end; end\n"
    )
    assert_finding r, :r1, /Order reaches Mailer from a model callback/
  end

  def test_templates_rendering_peers_and_calling_helpers
    r = lint(
      "app/views/carts/show.html.erb" => "<%= render \"components/row\", row: 1 %>\n",
      "app/views/components/_row.html.erb" => "<div id=\"<%= row_id(1) %>\"><%= render \"components/badge\" %></div>\n",
      "app/views/components/_badge.html.erb" => "<span>x</span>\n",
      "app/helpers/ids_helper.rb" => "module IdsHelper\n  def row_id(i) = \"row_\#{i}\"\nend\n",
      layers: [{ name: :application, paths: [%r{\Aapp/views/(?!components)}] }, { name: :domain, paths: [%r{\Aapp/views/components/}, %r{\Aapp/helpers/}] }]
    )
    assert_finding r, :r1, /_row renders app\/views\/components\/_badge: cross-peer/
    assert_finding r, :r1, /_row calls helper IdsHelper: cross-peer/
    refute_finding r, :r1, /carts\/show/
  end

  def test_cycles_without_a_layer_map
    r = lint({ "lib/a.rb" => "class A; def x = B.y; end\n", "lib/b.rb" => "class B; def self.y = A.new; end\n" }, layers: nil)
    assert_finding r, :r1, /dependency cycle: A → B → A/
    assert_equal :unchecked, r.rules[:r3][:state]
    assert_nil r.coverage
  end

  def test_tag_overrides_the_path_and_an_unknown_tag_is_a_validity_error
    r = lint(
      "domain/screen.rb" => "# @ala_layer application\nclass Screen; def go = Thing.new; end\n",
      "domain/thing.rb" => "class Thing; def x; end; end\n",
      "domain/odd.rb" => "# @ala_layer nowhere\nclass Odd; def x; end; end\n"
    )
    refute_finding r, :r1, /Screen/
    assert_finding r, :layer, /@ala_layer nowhere names no declared layer/
  end

  def test_unassigned_units_are_reported_and_counted_in_coverage
    r = lint("domain/a.rb" => "class A; def x; end; end\n", "elsewhere/b.rb" => "class B; def x; end; end\n")
    assert_finding r, :unassigned, /B matches no layer/
    assert_equal 1, r.coverage[:unassigned].size
    refute r.passes_min_score? == false
  end

  def test_uses_matcher_beats_the_path
    r = lint(
      "domain/rec.rb" => "class Rec < ApplicationRecord; def x; end; end\n",
      "domain/reader.rb" => "class Reader; def x = Rec.first; end\n",
      layers: [{ name: :application, paths: [%r{\Aapp/}] }, { name: :domain, paths: [%r{\Adomain/}] }, { name: :foundation, paths: [], uses: [/ApplicationRecord/] }]
    )
    assert_equal :foundation, r.model.unit("Rec").layer.name
    refute_finding r, :r1
  end

  def test_subscribe_flags_a_lower_unit_fixing_its_own_topic
    r = lint(
      "domain/mini.rb" => "class Mini\n  def start = ActiveSupport::Notifications.subscribe(\"cart.changed\") { }\n  def fine(topic) = ActiveSupport::Notifications.subscribe(topic) { }\nend\n",
      "foundation/bus.rb" => "class Bus; def self.start = Turbo::StreamsChannel.subscribe(\"x\"); end\n"
    )
    assert_finding r, :subscribe, /Mini#start subscribes a topic it fixes/
    refute_finding r, :subscribe, /Mini#fine/
    refute_finding r, :subscribe, /Bus/
  end

  def test_height_past_the_ceiling
    files = (1..7).to_h { |i| ["domain/c#{i}.rb", "class C#{i}; def x = #{i < 7 ? "C#{i + 1}.new" : 1}; end\n"] }
    r = lint(files, layers: [{ name: :application, paths: [%r{\Aapp/}] }, { name: :domain, paths: [%r{\Adomain/}], peer_ok: true }])
    assert_finding r, :height, /abstraction height 6 exceeds 5/
    r = lint(files, layers: [{ name: :application, paths: [%r{\Aapp/}] }, { name: :domain, paths: [%r{\Adomain/}], peer_ok: true }], set: { "height.max" => 6 })
    refute_finding r, :height
  end
end

class DataTest < Minitest::Test
  include LintHelper

  def test_a_record_read_by_two_peers_is_r10_and_by_the_composition_is_not
    r = lint(
      "domain/order.rb" => "class Order < ApplicationRecord; def x; end; end\n",
      "domain/cart.rb" => "class Cart; def x = Order.find(1); end\n",
      "domain/checkout.rb" => "class Checkout; def x = Order.where(a: 1); end\n",
      "domain/builder.rb" => "class Builder; def x = Order.new; end\n",
      "app/page.rb" => "class Page; def x = Order.all; end\n",
      layers: [{ name: :application, paths: [%r{\Aapp/}] }, { name: :domain, paths: [%r{\Adomain/}] }]
    )
    assert_finding r, :r10, /Order is read by Cart, Checkout, peers in domain/
    refute_finding r, :r10, /Builder/
  end

  def test_a_lower_aggregate_is_the_advisory_and_scored_under_strict
    files = {
      "domain/cart.rb" => "class Cart; def x = Account.first; def m = Money.new(1); end\n",
      "domain/checkout.rb" => "class Checkout; def x = Account.last; def m = Money.new(2); end\n",
      "foundation/account.rb" => "class Account < ApplicationRecord; def x; end; end\n",
      "foundation/money.rb" => "module Foundation; Money = Data.define(:cents) { def +(o) = with(cents: cents + o.cents) }; end\n",
      "foundation/row.rb" => "Row = Data.define(:name, :amount)\n",
      "domain/wish.rb" => "class Wish; def x = Row.new(1, 2); def y = Account.first; end\n"
    }
    r = lint(files)
    assert_finding r, :r10_aggregate, /Account \(foundation\) is read by Cart, Checkout, Wish/
    refute_finding r, :r10_aggregate, /Money/
    refute_finding r, :r10_aggregate, /Row/
    assert_equal "Foundation::Money", r.model.unit("Foundation::Money").name
    refute r.scored.any? { _1.check == :r10_aggregate }
    assert lint(files, tier: :strict).scored.any? { _1.check == :r10_aggregate }
  end

  def test_associations
    r = lint(
      "foundation/line.rb" => "class Line < ApplicationRecord\n  belongs_to :cart\n  belongs_to :product\n  has_many :notes\nend\n",
      config: { identity_models: %w[Cart] }
    )
    refute_finding r, :r10, /belongs_to :cart/
    assert_finding r, :r10, /belongs_to :product: reads another feature's record through Product/
    assert_finding r, :r10, /has_many :notes: lets a feature walk into another's table \(Note\)/
  end
end

class ResolutionTest < Minitest::Test
  include LintHelper

  def test_framework_bases_and_namespaced_constants
    r = lint(
      "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n",
      "app/models/cart.rb" => "class Cart < ApplicationRecord; def x; end; end\n",
      "domain/foundation.rb" => "module Foundation\n  Money = Data.define(:cents)\n  class Later < ApplicationJob; def perform; end; end\nend\n",
      "domain/user.rb" => "class User; def t = Screens::Checkout::TEXTS; def u = Screens::Checkout::NOPE; end\n",
      "app/screens/checkout.rb" => "module Screens; class Checkout; TEXTS = {}.freeze; def x; end; end; end\n",
      layers: [{ name: :application, paths: [%r{\Aapp/screens}] }, { name: :domain, paths: [%r{\Adomain/}] }, { name: :foundation, paths: [%r{\Aapp/models/}] }]
    )
    refute_finding r, :r1, /subclasses ApplicationRecord/
    refute_finding r, :r1, /Later/
    assert_finding r, :r1, /User#t references Screens::Checkout .*flows UP/
    assert_equal 1, messages(r, :r1).grep(/User/).size
  end
end

class HelperDeclarationTest < Minitest::Test
  include LintHelper

  def test_a_module_declared_with_helper_is_a_helper_unit
    r = lint(
      "app/application_controller.rb" => "class ApplicationController < ActionController::Base\n  helper Foundation::DomTargets\nend\n",
      "app/views/components/_row.html.erb" => "<div id=\"<%= row_id(1) %>\"></div>\n",
      "foundation/dom_targets.rb" => "module Foundation\n  module DomTargets\n    def row_id(i) = \"row_\#{i}\"\n  end\nend\n",
      layers: [{ name: :application, paths: [%r{\Aapp/(?!views/components)}] }, { name: :domain, paths: [%r{\Aapp/views/components/}] }, { name: :foundation, paths: [%r{\Afoundation/}] }]
    )
    assert r.model.edges.any? { |from, to, ref| from.name.end_with?("_row") && to.name == "Foundation::DomTargets" && ref.kind == :helper }
    refute_finding r, :r1
  end
end
