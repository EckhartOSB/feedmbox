#!/usr/bin/env ruby
#
# Script to read feeds and convert to mbox mail format.
#
# Input must be OPML, output will be mbox
#
require 'optparse'
require 'rubygems'
require 'nokogiri'
require 'mechanize'
require 'mailfactory'
require 'htmlentities'
require 'sqlite3'

def html2text html
  text = html.
    gsub(/(&nbsp;|\n|\s)+/im, ' ').squeeze(' ').strip.
    gsub(/<([^\s]+)[^>]*(src|href)=\s*(.?)([^>\s]*)\3[^>]*>\4<\/\1>/i, '\4')

  links = []
  linkregex = /<[^>]*(src|href)=\s*(.?)([^>\s]*)\2[^>]*>\s*/i
  while linkregex.match(text)
    links << $~[3]
    alt = ''
    if /\b(title|alt)=(['"])(.*?)\2/.match($~[0])
      alt = '[' + $~[3] + ']'
    end
    text.sub!(linkregex, "[#{links.size}]#{alt}")
  end

  decoder = HTMLEntities.new

  text = decoder.decode(
    text.
      gsub(/<(script|style)[^>]*>.*<\/\1>/im, '').
      gsub(/<!--.*-->/m, '').
      gsub(/<hr(| [^>]*)>/i, "___\n").
      gsub(/<li(| [^>]*)>/i, "\n* ").
      gsub(/<blockquote(| [^>]*)>/i, '> ').
      gsub(/<(br)(| [^>]*)>/i, "\n").
      gsub(/<(\/h[\d]+|p)(| [^>]*)>/i, "\n\n").
      gsub(/<[^>]*>/, '')
  ).lstrip.gsub(/\n[ ]+/, "\n") + "\n"

  for i in (0...links.size).to_a
    text = text + "\n  [#{i+1}] <#{decoder.decode(links[i])}>" unless links[i].nil?
  end
  links = nil
  text
end

verbose = false
recip = "nobody@example.com"
database = '~/.feedmbox'

optparse = OptionParser.new do |opts|
  opts.banner = 'usage: feedmbox.rb [-hv] [-t RECIPIENT]'

  opts.on('-d', '--database FILE', 'Specify database location') do |db|
    database = db
  end

  opts.on('-h', '--help', 'Print helpful information') do
    $stderr.puts optparse
  end

  opts.on('-t', '--to RECIPIENT', 'Specify recipient') do |to|
    recip = to
  end

  opts.on('-v', '--verbose', 'Verbose output on stderr') do
    verbose = true
  end
end

begin
  optparse.parse!
rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
  $stderr.puts e
  $stderr.puts optparse
  exit 1
end

class NilClass
  def inner_text
    nil
  end
end

class MailFactory
  def hdr(field, e)
    self.set_header(field, e.inner_text) if e
  end
end

database = File.expand_path(database)
newdb = !File.exists?(database)
db = SQLite3::Database.new(database)
retries = 60
retry_interval = 5
db.busy_handler() do |retries|
  rval = 1
  if retries && (retries >= retries)
    rval = 0
  else
    sleep retry_interval
  end
  rval
end
if newdb
  db.execute("create table HISTORY (
	    guid VARCHAR(1024) NOT NULL UNIQUE PRIMARY KEY
	    );")
end

opml = Nokogiri::XML::parse $<.read
feeds = opml.xpath("//outline[@type='rss']|//outline[@type='atom']")
feeds.each do |feed|
  $stderr.puts "Polling: #{feed.get_attribute('text')}" if verbose
  xmlurl = feed.get_attribute("xmlUrl")
  if xmlurl
    begin
      xml = Nokogiri::XML::parse Mechanize.new.get(xmlurl).body
      channel = nil
      items = []
      chanlink = nil
      chanauthor = nil
      subtitle = nil
      if (channel = xml.at('rss/channel'))	# RSS 2.0
        items = channel.xpath('item')
	chanlink = channel.at('link').inner_text
	subtitle = channel.at('description')
      elsif (channel = xml.at('feed'))		# ATOM 1.0
        items = channel.xpath('entry')
	chanlink = channel.at('link')
	chanlink = chanlink ? chanlink.attribute('href') : ''
	chanauthor = channel.at('author/name')
	subtitle = channel.at('subtitle')
      else
        raise "Not an RSS 2.0 or ATOM 1.0 feed"
      end
      count = 0
      items.each do |item|
	itemlink = item.at('link')
	itemlink = itemlink.attribute('href') || itemlink.inner_text
	guid = "#{xmlurl}/#{((item.at('guid') || item.at('id')).inner_text || itemlink)}"
        if (!db.get_first_row("select guid from HISTORY where guid = ?", guid))
	  db.execute("insert into HISTORY (guid) values (?)", guid)
	  mail = MailFactory.new
	  textnode = item.at('content') || item.children.find {|c| c.name == 'encoded' } || item.at('description') || item.at('summary')
	  mail.text = html2text(textnode.inner_text || '')
	  mail.set_header("To", recip)
	  mail.hdr("From", channel.at('title'))
	  mail.hdr("Subject", item.at('title'))
	  date = item.at('pubDate') || item.at('published') || channel.at('pubDate')
	  date = date ? DateTime.parse(date.inner_text) : Time.now
	  mail.set_header("Date", date.strftime("%a, %b %d %Y %H:%M:%S"))
	  mail.set_header("List-Id", sprintf("%s <%s>", (channel.at('title').inner_text || ''), xmlurl))
	  mail.set_header("Content-Location", chanlink)
	  mail.hdr("X-Feed-Subtitle", subtitle)
	  mail.hdr("X-Item-Author", (item.children.find {|c| c.name == 'creator' } || item.at('author/name') || item.at('author') || chanauthor))
	  mail.hdr("X-Item-Category", item.at('category'))
	  mail.set_header("X-Item-Link", itemlink)
	  puts "From feedmbox #{date.strftime('%a %b %d %H:%M:%S %Y')}"
	  puts mail.to_s.gsub("\r","")		# MailFactory malefactory
	  puts ""
	  count += 1
        end
      end
      $stderr.puts "  #{count} new item#{'s' if count != 1}" if (verbose && (count > 0))
    rescue Interrupt
      exit
    rescue Exception => e
      $stderr.puts "Error in feed '#{xmlurl}': #{e}"
    end
  end
end
