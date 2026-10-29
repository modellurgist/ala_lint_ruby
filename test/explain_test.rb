require_relative "test_helper"
require "stringio"

class ExplainTest < Minitest::Test
  SCORED = "SCORED IN THIS RUN"
  REPORTED = "REPORTED, NOT SCORED"
  JUDGED = "APPLIES, BUT NOT MACHINE-CHECKED"

  def explain(raw = {}, **opts) = AlaLint::Explain.text(AlaLint::Config.new(Dir.tmpdir, raw, opts))

  def section(text, heading)
    text.split("#{heading}\n", 2).last.split(/\n(?=[A-Z][A-Z ,-]+\n)|\nNot adopted in this run/, 2).first
  end

  def lists?(section, check) = section.match?(/^\s{4,}#{check}\s{2,}/)
  def rule?(section, rule) = section.match?(/^  #{rule} /)

  def test_the_default_tier_scores_the_required_checks_and_reports_r7_and_r11
    text = explain
    scored = section(text, SCORED)
    reported = section(text, REPORTED)
    %w[r1 layer r2 r3 r4 r5 r6 r9 r10].each { assert lists?(scored, _1), _1 }
    %w[R1 R2 R3 R4 R5 R6 R9 R10].each { assert rule?(scored, _1), _1 }
    refute rule?(scored, "R7")
    refute rule?(scored, "R11")
    %w[r7 clone height passthrough tramp subscribe ports r10_aggregate r11 public_surface ports_unwired].each { assert lists?(reported, _1), _1 }
    assert rule?(reported, "R11")
    assert_includes text, "Not adopted in this run: none"
  end

  def test_strict_scores_the_obtainable_advisories_and_keeps_r11_reported
    text = explain({}, tier: :strict)
    %w[r7 clone height passthrough tramp subscribe ports ui_io r10_aggregate module_size].each { assert lists?(section(text, SCORED), _1), _1 }
    assert lists?(section(text, REPORTED), "r11")
    assert lists?(section(text, REPORTED), "public_surface")
    refute lists?(section(text, REPORTED), "r7")
    assert lists?(section(explain({}, tier: :super_strict), SCORED), "r11")
  end

  def test_light_ala_leaves_r9_to_r11_out_but_for_one_line_and_lists_the_conventions
    text = explain({ preset: :light_ala })
    body, tail = text.split("Not adopted in this run:", 2)
    assert_match(/\A R9, R10, R11\n?\z/, tail)
    refute_match(/\bR(9|10|11)\b/, body)
    %w[ports ports_unwired r11_share app_share r10_aggregate].each { refute lists?(body, _1), _1 }
    judged = section(text, JUDGED)
    assert_includes judged, "a checklist reading for light ALA, not Spray's ALA"
    [5, 6, 8, 9, 10, 11, 12].each { assert_match(/^\s+rule #{n = _1}\s/, judged, "rule #{n}") }
  end

  def test_a_file_checks_setting_and_disable_change_the_listing
    text = explain({ checks: { r7: :scored, r3: :off } })
    assert lists?(section(text, SCORED), "r7")
    refute_match(/^\s+r3\s{2,}/, text)
    refute rule?(section(text, SCORED), "R3")

    text = explain({}, disable: %w[r6 tramp ui_io])
    assert_includes text, "Not adopted in this run: R6"
    refute_match(/^  R6 /, text)

    text = explain({ checks: { r3: :advisory } })
    assert lists?(section(text, REPORTED), "r3")
    refute lists?(section(text, SCORED), "r3")
  end

  def test_enforce_scores_one_check_and_a_later_disable_wins
    assert lists?(section(explain({}, enforce: %w[r11]), SCORED), "r11")
    refute_match(/^\s+r11\s{2,}/, explain({}, enforce: %w[r11], disable: %w[r11]))
  end

  def test_the_not_machine_checked_section_always_includes_r8
    all = AlaLint::Checks::ALL.map(&:name)
    [[{}, {}], [{ preset: :light_ala }, {}], [{}, { tier: :super_strict }], [{}, { disable: all }]].each do |raw, opts|
      assert_match(/^  R8 /, section(explain(raw, **opts), JUDGED), [raw, opts].inspect)
    end
  end

  def test_every_check_has_a_line_to_explain_it
    AlaLint::Checks::ALL.each { assert AlaLint::Explain.describes?(_1.name), _1.name.to_s }
  end

  def test_the_default_output_stays_short_and_light_alas_shorter
    default = explain.lines.size
    light = explain({ preset: :light_ala }).lines.size
    assert_includes 60..90, default, "default: #{default} lines"
    assert_operator light, :<, default
  end

  def test_the_cli_prints_the_guide_without_reading_any_code
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".ala_lint.rb"), "{ preset: :light_ala, paths: %w[nowhere] }")
      out = StringIO.new
      assert_equal 0, AlaLint::CLI.run(["--root", dir, "--explain", "--strict"], out: out)
      assert_includes out.string, SCORED
      assert_includes out.string, "tier: --strict  preset: light_ala"
      refute_includes out.string, "Degree of function compliance"
    end
  end
end
