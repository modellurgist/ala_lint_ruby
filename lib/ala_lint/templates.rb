require "erb"

module AlaLint
  # Reads an ERB template as a unit: the Ruby it compiles to is parsed like any file, and its text
  # nodes become `texts` (what a lower layer's markup says) and the identifier-like attribute values
  # (`id=`, `data-*=`, `name=`) become strings a contract check can see. `render "components/x"`
  # becomes a reference to that partial's unit.
  class Templates
    LABEL_ATTRS = %w[placeholder title aria-label label alt value].freeze
    ID_ATTRS = %w[id name data-controller data-action data-turbo-frame for].freeze

    def self.parse(file, root)
      new(file, root).parse
    end

    def initialize(file, root)
      @file = file
      @root = root
    end

    def parse
      src = File.read(@file)
      ruby = ERB.new(src, trim_mode: "-").src
      unit = Parser.parse(@file, @root, source: ruby).first
      unit.name = name
      unit.file = @file
      unit.kind = :template
      unit.line = 1
      unit.end_line = src.lines.size
      unit.loc = src.lines.count { !_1.strip.empty? }
      unit.methods = []
      shift_lines(unit, -1)
      unit.header_comment = src[/\A<%#\s*(.*?)%>/m, 1].to_s
      unit.tag = unit.header_comment[/@ala_layer\s+:?(\w+)/, 1]
      split_markup(unit)
      unit.calls.each { |c| partial_ref(unit, c) }
      unit
    end

    private

    def name = @file.delete_prefix(@root).delete_prefix("/").sub(/\.html\.erb\z/, "").sub(/\.erb\z/, "")

    # ERB's compiled source starts with a `#coding` line, so every Prism line is one too many.
    def shift_lines(unit, by)
      unit.methods.each { _1.line += by; _1.end_line += by }
      (unit.refs + unit.calls + unit.literals + unit.strings + unit.ivar_writes).each { _1.line += by }
      unit.macros.each { _1.line += by }
    end

    # The strings `_erbout << "..."` appends are markup, not Ruby strings: keep the text a person
    # reads and the attribute values two sides could agree on, and drop the rest.
    def split_markup(unit)
      markup, ruby = unit.strings.partition { _1.context == :"call_<<" || erbout_string?(unit, _1) }
      unit.strings = ruby.reject { css_string?(_1) }
      markup.each do |s|
        html = s.value
        LABEL_ATTRS.each { |a| html.scan(/\b#{a}="([^"]+)"/) { |(v)| unit.texts << Source::Str.new(value: v, line: s.line, method: nil, context: :"attr_#{a}", interpolated: false, words: v.scan(/[A-Za-z][a-z']+/)) } }
        ID_ATTRS.each { |a| html.scan(/\b#{a}="([^"]+)"/) { |(v)| unit.strings << Source::Str.new(value: v, line: s.line, method: nil, context: :"attr_#{a}", interpolated: false, words: []) } }
        text = html.gsub(/<[^>]*>/, " ").gsub(/&\w+;/, " ").strip
        next if text.empty?
        unit.texts << Source::Str.new(value: text, line: s.line, method: nil, context: :text, interpolated: false, words: text.scan(/[A-Za-z][a-z']+/))
      end
    end

    # ERB appends markup as `_erbout.<< "...".freeze`, so the string sits under a `.freeze` call.
    def erbout_string?(unit, str)
      @markup ||= unit.calls.select { _1.name == :<< && _1.receiver_name == "_erbout" }.filter_map do |c|
        arg = c.args.first
        arg = arg.receiver if arg.is_a?(Prism::CallNode) && arg.name == :freeze
        arg.respond_to?(:unescaped) ? [arg.location.start_line - 1, arg.unescaped] : nil
      end.to_set
      @markup.include?([str.line, str.value])
    end

    def css_string?(str) = str.context == :key_class || str.context == :key_data

    def partial_ref(unit, call)
      return unless call.name == :render
      target = call.args.find { _1.is_a?(Prism::StringNode) }&.unescaped
      if target.nil?
        kw = call.args.find { _1.is_a?(Prism::KeywordHashNode) }
        partial = kw&.elements&.find { _1.is_a?(Prism::AssocNode) && _1.key.respond_to?(:unescaped) && _1.key.unescaped == "partial" }
        target = partial&.value&.unescaped if partial&.value.is_a?(Prism::StringNode)
      end
      return unless target
      unit.refs << Source::Ref.new(name: "partial:#{target}", resolved: nil, kind: :render, line: call.line, method: nil, callback: false)
    end
  end
end
