require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/ala_lint"
require_relative "../lib/ala_lint/cli"

# Writes a small project to a temp dir, lints it, and returns the Report. Layers default to one
# directory per layer, top first.
module LintHelper
  LAYERS = [
    { name: :application, paths: [%r{\Aapp/}] },
    { name: :domain, paths: [%r{\Adomain/}] },
    { name: :paradigms, paths: [%r{\Aparadigms/}] },
    { name: :foundation, paths: [%r{\Afoundation/}], peer_ok: true }
  ].freeze

  def lint(files = {}, layers: LAYERS, config: {}, **opts)
    files = files.merge(opts.select { |k, _| k.is_a?(String) })
    opts = opts.reject { |k, _| k.is_a?(String) }
    dir = Dir.mktmpdir("ala_lint")
    files.each do |path, src|
      full = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, src)
    end
    File.write(File.join(dir, ".ala_lint.rb"), "{ layers: #{layers.inspect}, paths: #{files.keys.map { _1.split('/').first }.uniq.inspect} }.merge(#{config.inspect})") if layers || !config.empty?
    AlaLint.analyze(dir, **opts)
  ensure
    FileUtils.rm_rf(dir)
  end

  def findings(report, check) = report.findings.select { _1.check == check }
  def messages(report, check) = findings(report, check).map(&:message)
  def assert_finding(report, check, pattern) = assert(messages(report, check).any? { _1.match?(pattern) }, "expected a #{check} finding matching #{pattern.inspect}; got:\n#{messages(report, check).join("\n")}")
  def refute_finding(report, check, pattern = //) = refute(messages(report, check).any? { _1.match?(pattern) }, "unexpected #{check} finding matching #{pattern.inspect}:\n#{messages(report, check).join("\n")}")
end
