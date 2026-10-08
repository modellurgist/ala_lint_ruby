require_relative "test_helper"

class StateTest < Minitest::Test
  include LintHelper

  def test_shared_mutable_state_forms
    r = lint(
      "domain/a.rb" => "class A\n  @@count = 0\n  def x = Thread.current[:cart]\n  def y = Current.cart\n  def self.cache = @cache ||= {}\n  def z = $registry = 1\nend\n",
      "foundation/ports.rb" => "module Ports\n  def self.outputs = @outputs ||= {}\nend\n"
    )
    assert_finding r, :r2, /class variable @@count/
    assert_finding r, :r2, /Thread.current/
    assert_finding r, :r2, /reads Current.cart below the composition/
    assert_finding r, :r2, /A.cache keeps class-level state @cache/
    assert_finding r, :r2, /writes global \$registry/
    refute_finding r, :r2, /Ports/
  end

  def test_composition_fields_after_construction_and_the_landing_exemptions
    r = lint(
      "app/screen.rb" => "class Screen\n  def initialize = @a.on(:rows) { @rows = _1 }\n  def step = @total = @cart.total\n  def memo = @cart ||= Cart.new\nend\n",
      "app/pages_controller.rb" => "class PagesController < ApplicationController\n  def show(title)\n    @s = screen\n    @t = Screen::TEXTS\n    @title = title\n    @sum = @s.lines.sum\n  end\nend\n",
      "domain/cart.rb" => "class Cart; def total; end; end\n"
    )
    assert_finding r, :r4, /Screen#step assigns @total after construction/
    refute_finding r, :r4, /@rows/
    refute_finding r, :r4, /memo/
    refute_finding r, :r4, /@s |@t |@title/
    assert_finding r, :r4, /PagesController#show assigns @sum/
  end

  def test_leaked_state_in_a_domain_class
    r = lint(
      "domain/cart.rb" => "class Cart\n  attr_reader :lines, :name\n  def initialize = (@lines = []; @lock = Mutex.new)\n  def add(l) = @lines << l\n  def peek(o) = o.instance_variable_get(:@x)\nend\n"
    )
    assert_finding r, :r4, /exposes @lines with attr_reader and mutates it/
    refute_finding r, :r4, /@name/
    assert_finding r, :r4, /creates a Mutex/
    assert_finding r, :r4, /reaches into another object's instance variables/
  end
end

class LiteralsTest < Minitest::Test
  include LintHelper

  def test_numbers_below_the_composition
    r = lint(
      "app/store.rb" => "class Store; RATE = 599; end\n",
      "domain/ship.rb" => "class Ship\n  def cost(s) = s > 5000 ? 0 : 599\n  def pct(x) = x * 10 / 100\n  def idx(a) = a[2]\n  def boom = raise(ArgumentError, 42)\nend\n"
    )
    assert_finding r, :r3, /literal 5000 in Ship#cost/
    assert_finding r, :r3, /literal 599 in Ship#cost/
    refute_finding r, :r3, /literal 100/
    refute_finding r, :r3, /literal 2 /
    refute_finding r, :r3, /literal 42/
    refute_finding r, :r3, /Store/
  end

  def test_words_below_the_composition_but_not_in_the_bottom_layer
    r = lint(
      "domain/wish.rb" => "class Wish\n  def add = \"Saved to wishlist\"\n  def say(n) = \"Hello \#{n}, welcome back\"\n  def css = \"flex items-center gap-2\"\n  def key = I18n.t(\"cart.added\")\n  def log = Rails.logger.info(\"Added a line\")\nend\n",
      "domain/form.rb" => "class Form < ApplicationRecord\n  validates :po, format: { with: /x/, message: \"must look like PO-1234\" }\nend\n",
      "domain/money.rb" => "class Money; def initialize = @c = Money.new(1, currency: \"USD\"); end\n",
      "foundation/ports.rb" => "class Ports; def oops = raise(\"No port named here\"); def diag = \"Not wired yet\"; end\n",
      layers: LAYERS.map { _1[:name] == :domain ? _1.merge(uses: []) : _1 }
    )
    assert_finding r, :r3, /message text "Saved to wishlist"/
    assert_finding r, :r3, /sentence built by interpolation/
    refute_finding r, :r3, /flex items-center/
    assert_finding r, :r3, /looks up I18n key "cart.added"/
    refute_finding r, :r3, /Added a line/
    assert_finding r, :r3, /validation message "must look like PO-1234"/
    assert_finding r, :r3, /currency "USD"/
    refute_finding r, :r3, /Ports/
  end

  def test_product_defaults_and_peer_defaults
    r = lint(
      "domain/ship.rb" => "class Ship\n  def initialize(free_over: 10_000, sep: \"\", gateway: Stripe.new, n: 1) = nil\nend\n",
      "domain/stripe.rb" => "class Stripe; def charge; end; end\n"
    )
    assert_finding r, :r3, /defaults free_over: to 10_000: a default that may be a product decision/
    assert_finding r, :r3, /defaults gateway: to Stripe.new: a peer as a default/
    refute_finding r, :r3, /sep:/
    refute_finding r, :r3, /defaults n:/
  end

  def test_markup_words_in_a_lower_template_only
    r = lint(
      "app/views/pages/show.html.erb" => "<h1>Your Cart</h1>\n<%= render \"components/badge\" %>\n",
      "app/views/components/_badge.html.erb" => "<span class=\"flex items-center\">Only a few left!</span>\n<input placeholder=\"Promo code\">\n",
      layers: [{ name: :application, paths: [%r{\Aapp/views/(?!components)}] }, { name: :domain, paths: [%r{\Aapp/views/components/}] }, { name: :foundation, paths: [%r{\Afoundation/}] }]
    )
    assert_finding r, :r3, /markup text "Only a few left!"/
    assert_finding r, :r3, /markup text "Promo code"/
    refute_finding r, :r3, /Your Cart/
    refute_finding r, :r3, /flex items-center/
  end
end

class ContractsTest < Minitest::Test
  include LintHelper

  def test_duplicated_identifier_strings_across_units
    r = lint(
      "app/screen.rb" => "class Screen\n  def a = \"cart_changed\"\n  def b = \"shared_in_app\"\nend\n",
      "app/other.rb" => "class Other\n  def b = \"shared_in_app\"\n  def c = \"flex gap-2\"\nend\n",
      "domain/mini.rb" => "class Mini\n  def a = \"cart_changed\"\n  def t = \"text/html\"\n  def w(s) = s.end_with?(\"Helper\")\n  def x = render(\"components/row\")\nend\n",
      "domain/row.rb" => "class Row\n  def t = \"text/html\"\n  def w = \"Helper\"\n  def x = \"components/row\"\nend\n"
    )
    assert_finding r, :r5, /"cart_changed" also appears in Mini/
    refute_finding r, :r5, /shared_in_app/
    refute_finding r, :r5, /text\/html/
    refute_finding r, :r5, /Helper/
    refute_finding r, :r5, /components\/row/
  end

  def test_a_template_id_and_a_screen_string_agree
    r = lint(
      "app/screen.rb" => "class Screen\n  def target = \"checkout_status\"\nend\n",
      "app/views/components/_status.html.erb" => "<div id=\"checkout_status\">x</div>\n",
      layers: [{ name: :application, paths: [%r{\Aapp/screen}] }, { name: :domain, paths: [%r{\Aapp/views/components/}] }]
    )
    assert_finding r, :r5, /"checkout_status" also appears in app\/views\/components\/_status/
  end

  def test_money_label_restating_a_configured_amount_and_dynamic_names
    r = lint(
      "app/store.rb" => "class Store; WRAP = 299; end\n",
      "domain/wrap.rb" => "class Wrap\n  def label = \"Gift wrap ($2.99)\"\n  def other = \"Costs $4.50\"\n  def go(e) = send(\"handle_\#{e}\")\nend\n"
    )
    assert_finding r, :r5, /"Gift wrap \(\$2.99\)" in Wrap restates a configured amount \(299 cents\)/
    refute_finding r, :r5, /4.50/
    assert_finding r, :r5, /calls a method by a name built from a string/
  end
end

class InherentTextTest < Minitest::Test
  include LintHelper

  def test_words_under_an_inherent_constant_or_ivar_are_the_abstractions_own
    r = lint(
      "domain/badge.rb" => "class Badge\n  INHERENT_LABELS = { low: \"Only a few left!\", out: \"Out of stock\" }.freeze\n  LABELS = { empty: \"Your cart is empty.\" }.freeze\n  def self.words = @inherent_words ||= [ \"Next page\" ]\n  def say = \"Promo applied!\"\nend\n"
    )
    r3 = messages(r, :r3)
    refute r3.any? { _1.match?(/Only a few|Out of stock|Next page/) }, r3.join("\n")
    assert r3.any? { _1.match?(/Your cart is empty/) }
    assert r3.any? { _1.match?(/Promo applied/) }
    assert_includes r.accepted_listing, "domain/badge.rb:2  Badge::INHERENT_LABELS"
    assert_includes r.accepted_listing, "Badge::@inherent_words"
  end
end
