require_relative "test_helper"

class ClonesTest < Minitest::Test
  include LintHelper

  PRICE = <<~RB.freeze
    class Price
      def total(items)
        sum = items.sum { |i| i.amount * i.quantity }
        after = sum - sum * @rate / 100
        [ after, 0 ].max.round
      end
    end
  RB

  def test_a_renamed_copy_in_another_class
    copy = "class Charge\n  def due(lines)\n    gross = lines.sum { |l| l.amount * l.quantity }\n    net = gross - gross * @pct / 1000\n    [ net, 0 ].max.round\n  end\nend\n"
    r = lint("domain/price.rb" => PRICE, "domain/charge.rb" => copy)
    assert_finding r, :clone, %r{Charge#due \(domain/charge.rb:3\) and Price#total \(domain/price.rb:3\) are the same logic \(\d+ nodes\): one concept written twice}
    assert_finding r, :clone, /§7.25.*extract it into an abstraction both compose/
    assert_equal 1, findings(r, :clone).size
  end

  def test_a_copied_run_inside_a_larger_method
    larger = <<~RB
      class Checkout
        def place(lines, user)
          notify(user.email, user.name)
          gross = lines.sum { |l| l.amount * l.quantity }
          net = gross - gross * @pct / 100
          [ net, 0 ].max.round
          deliver(user.address)
          archive(lines, user.id)
        end
      end
    RB
    r = lint("domain/price.rb" => PRICE, "domain/checkout.rb" => larger)
    assert_finding r, :clone, %r{Checkout#place \(domain/checkout.rb:4\) and Price#total \(domain/price.rb:3\)}
  end

  def test_an_edited_copy_is_nearly_the_same
    edited = "class Charge\n  def due(lines)\n    gross = lines.sum { |l| l.amount * l.quantity }\n    net = gross - gross * @pct / 100\n    [ net, 0 ].max.round.to_i\n  end\nend\n"
    assert_finding lint("domain/price.rb" => PRICE, "domain/charge.rb" => edited), :clone, /nearly the same logic \(\d+ of \d+ nodes match\)/
  end

  def test_a_copy_below_the_threshold
    small = "class A\n  def label(x) = \"\#{x.name} (\#{x.code})\"\nend\n"
    other = "class B\n  def title(y) = \"\#{y.name} (\#{y.code})\"\nend\n"
    assert_empty findings(lint("domain/a.rb" => small, "domain/b.rb" => other), :clone)
    assert_empty findings(lint({ "domain/price.rb" => PRICE, "domain/charge.rb" => PRICE.sub("Price", "Charge") }, config: { checks: { clone: { min_nodes: 60 } } }), :clone)
  end

  def test_the_same_shape_with_different_calls_is_different_logic
    other = "class Weight\n  def heaviest(boxes)\n    top = boxes.max_by { |b| b.mass + b.volume }\n    load = top + top * @margin / 100\n    [ load, 1 ].min.ceil\n  end\nend\n"
    assert_empty findings(lint("domain/price.rb" => PRICE, "domain/weight.rb" => other), :clone)
  end

  def test_wiring_arms_part_placement_and_routing_are_not_clones
    screen = lambda do |name|
      <<~RB
        module Screens
          class #{name}
            def parts = { lines: @lines, items: @items, totals: @totals, flow: @flow }
            def initialize(cart_id:)
              @items = Items.new(model: CartItem, cart_id:, scope: :active)
              @lines = Lines.new(cart_id:, products: ->(ids) { Product.lookup(ids) }, links: ->(id) { { remove: id } })
              @totals = Totals.new(shipping: Shipping.new(rates: Store::RATES), wrap: Wrap.new(unit: Store::WRAP))
            end
            def show = render(turbo_stream: turbo_stream.replace(helpers.dom_id(@form, :form), partial: "x/form", locals: { form: @form, url: x_path }))
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
    end
    r = lint("app/cart.rb" => screen.("Cart"), "app/portal.rb" => screen.("Portal"))
    assert_empty findings(r, :clone)
  end

  def test_tiers_and_the_inside_variant
    two = PRICE.sub("end\nend", "end\n  def again(items)\n    sum = items.sum { |i| i.amount * i.quantity }\n    after = sum - sum * @rate / 100\n    [ after, 0 ].max.round\n  end\nend")
    copy = { "domain/price.rb" => PRICE, "domain/charge.rb" => PRICE.sub("Price", "Charge") }
    refute lint(copy).scored.any? { _1.check == :clone }
    assert lint(copy, tier: :strict).scored.any? { _1.check == :clone }
    r = lint({ "domain/price.rb" => two }, tier: :super_strict)
    assert_finding r, :clone_inside, /Price#total .* and Price#again .* inside one abstraction/
    assert_empty findings(r, :clone)
    refute r.scored.any? { _1.check == :clone_inside }
    accepted = PRICE.sub("Price", "Charge").sub("    sum =", "    # ala:accept clone -- kept apart until a second pricing rule exists\n    sum =")
    r = lint({ "domain/price.rb" => PRICE, "domain/charge.rb" => accepted }, tier: :strict)
    assert_empty findings(r, :clone)
    assert_equal [:clone], r.accepted.map(&:check)
  end
end
