#!/usr/bin/env ruby
# Insert a new <item> at the top of <channel> in appcast.xml.
#
# Usage:
#   scripts/update_appcast.rb <version> <build> <length> <ed_signature>

require "rexml/document"
require "time"

if ARGV.length != 4
  warn "usage: update_appcast.rb <version> <build> <length> <ed_signature>"
  exit 1
end

version, build, length, ed_sig = ARGV
appcast_path = File.expand_path("../appcast.xml", __dir__)

doc = REXML::Document.new(File.read(appcast_path))
channel = doc.root.elements["channel"] or raise "appcast.xml has no <channel>"

item = REXML::Element.new("item")
item.add_element("title").text = "Version #{version}"
item.add_element("sparkle:version").text = build
item.add_element("sparkle:shortVersionString").text = version
item.add_element("pubDate").text = Time.now.utc.rfc2822

enclosure = item.add_element("enclosure")
enclosure.attributes["url"] =
  "https://github.com/sohonetlabs/testfs/releases/download/v#{version}/TestFS-#{version}.dmg"
enclosure.attributes["sparkle:edSignature"] = ed_sig
enclosure.attributes["length"] = length
enclosure.attributes["type"] = "application/octet-stream"

item.add_element("sparkle:minimumSystemVersion").text = "15.4"

first_item = channel.elements["item"]
first_item ? channel.insert_before(first_item, item) : channel.add_element(item)

# REXML::Formatters::Default preserves whitespace from the source doc
# rather than re-flowing it, so re-running this script doesn't churn
# unrelated lines in the diff.
output = +""
REXML::Formatters::Default.new.write(doc, output)
File.write(appcast_path, output + "\n")
