# frozen_string_literal: true

require "cgi"
require "jekyll"
require "liquid"

# Keeps published email addresses away from harvesters.
#
# The scraper-facing half is deliberately server-side: when the feature is on,
# no `mailto:` string and no `user@host` string is present in the HTML at all.
# Address harvesters read markup, not JavaScript, so an approach that ships the
# plaintext and merely rewrites it on DOMContentLoaded protects nobody. The
# address is emitted as two halves and only rejoined in the browser.
module AlEmailProtect
  module_function

  def enabled?(site)
    return false unless site

    site.config["protect_email"] == true
  end

  # Splits "someone@example.ac.uk" into ["someone", "example.ac.uk"].
  def split_address(value)
    address = value.to_s.strip
    return nil if address.empty?

    local, _, domain = address.rpartition("@")
    return nil if local.empty? || domain.empty?
    return nil unless domain.include?(".")

    [local, domain]
  end

  # "someone [at] example [dot] com", for places that show an address as text
  # rather than as a link (CV contact blocks, for instance).
  def obfuscate_text(value)
    parts = split_address(value)
    return value.to_s unless parts

    local, domain = parts
    "#{local} [at] #{domain.gsub(".", " [dot] ")}"
  end

  def escape(value)
    CGI.escapeHTML(value.to_s)
  end

  # Builds "example [dot] com" as alternating styled spans.
  def domain_markup(domain)
    separator = %(<span class="al-email-sep"> [dot] </span>)
    domain.split(".").map { |label| %(<span class="al-email-text">#{escape(label)}</span>) }.join(separator)
  end

  # {% al_email_protect_link site.email %}
  #
  # Emits a click-to-copy element carrying the address in halves. Falls back to
  # a plain mailto: link when the feature is off, so a layout can call this
  # unconditionally and get correct markup either way.
  class LinkTag < Liquid::Tag
    def initialize(tag_name, markup, options)
      super
      @markup = markup.strip
    end

    def render(context)
      value = context[@markup]
      value = @markup.gsub(/\A["']|["']\z/, "") if value.nil?
      return "" if value.to_s.strip.empty?

      parts = AlEmailProtect.split_address(value)
      unless AlEmailProtect.enabled?(context.registers[:site]) && parts
        escaped = AlEmailProtect.escape(value)
        return %(<a href="mailto:#{escaped}">#{escaped}</a>)
      end

      local, domain = parts
      [
        %(<a href="#" class="al-email-protect" data-eu="#{AlEmailProtect.escape(local)}" data-ed="#{AlEmailProtect.escape(domain)}">),
        %(<span class="al-email-text">#{AlEmailProtect.escape(local)}</span>),
        %(<span class="al-email-sep"> [at] </span>),
        AlEmailProtect.domain_markup(domain),
        %(</a>),
      ].join
    end
  end

  ANCHOR = %r{<a\b([^>]*?)href=(["'])mailto:([^"']+)\2([^>]*)>(.*?)</a>}im.freeze

  def decode_target(value)
    CGI.unescape(value.to_s.split("?").first.to_s)
  rescue StandardError
    value.to_s
  end

  def rewrite_html(html)
    html.to_s.gsub(ANCHOR) do
      before = Regexp.last_match(1)
      after = Regexp.last_match(4)
      address = decode_target(Regexp.last_match(3))
      label = Regexp.last_match(5)
      parts = split_address(address)

      next Regexp.last_match(0) unless parts

      local, domain = parts
      attributes = "#{before}#{after}".gsub(/\s+/, " ").strip
      inner = label.to_s.include?("@") ? "<span class=\"al-email-text\">#{escape(local)}</span><span class=\"al-email-sep\"> [at] </span>#{domain_markup(domain)}" : label

      attr_suffix = attributes.empty? ? "" : " #{attributes}"
      %(<a href="#" class="al-email-protect"#{attr_suffix} data-eu="#{escape(local)}" data-ed="#{escape(domain)}">#{inner}</a>)
    end
  end

  module Filters
    def al_email_obfuscate(value)
      return value.to_s unless AlEmailProtect.enabled?(@context.registers[:site])

      AlEmailProtect.obfuscate_text(value)
    end

    def al_email_protect_html(value)
      return value.to_s unless AlEmailProtect.enabled?(@context.registers[:site])

      AlEmailProtect.rewrite_html(value)
    end
  end
end

Liquid::Template.register_tag("al_email_protect_link", AlEmailProtect::LinkTag)
Liquid::Template.register_filter(AlEmailProtect::Filters)
