require "http/client"
require "json"
require "option_parser"


def scope(&)
  # When you want to run some code in its own scope
  # instead of polluting your variables everywhere
  return yield
end

def array_to_slice(array : Array(T)) : Slice(T) forall T
  # UNSAFE: is there really no better way to convert an array to a slice?
  return Slice.new(array.to_unsafe, array.size)
end

class Property
  include JSON::Serializable

  def initialize(@key : String, @value : String)
  end
end

class Block
  include JSON::Serializable

  def initialize(type : String)
    @type = type.upcase
    # this could technically be a Hash but we care about insertion order
    # to be able to do language-agnostic diff's on the input and output
    @properties = Array(Property).new
    @children = Array(Block).new
  end

  def []?(key : String) : String?
    # always case insensitive key comparison
    key = key.upcase
    return @properties.each do |prop|
      # TODO: what if we have several?
      break prop.@value if prop.@key.upcase == key
    end
  end
end

def retrieve(url : String, & : IO -> T) : T forall T
  HTTP::Client.get url do |response|
    raise "Status #{response.status_code}" if response.status_code != 200
    return yield response.body_io
  end
end

def unwrap_lines(io : IO, & : String ->)
  loop do
    # stop if we reached the end
    peek = io.peek
    break if peek.nil? || peek.size == 0

    # Read byte-by-byte
    lineb = Array(UInt8).new
    loop do
      b = io.read_byte
      break if b.nil?

      # If we come across \r\n
      if b.chr == '\r'
        nb = io.read_byte
        raise "CR without LF" if nb.nil? || nb.chr != '\n'

        # keep going if the first character of the next line is a space,
        # because then we're on a folded line
        peek = io.peek
        break if peek.nil? || peek.size == 0

        if peek[0].chr == ' '
          # do pop the space, we don't want it
          io.read_byte
        else
          break
        end
      else
        lineb << b
      end
    end

    # convert back to a string
    yield String.new array_to_slice lineb if !lineb.empty?
  end
end

def parse_io(io : IO) : Block
  stack = Deque(Block).new

  unwrap_lines(io) do |line|
    # always case insensitive key comparison
    upline = line.upcase

    if upline.starts_with? "BEGIN:"
      # Begin objects
      _, type = line.split ':'
      block = Block.new type
      stack << block
    elsif upline.starts_with? "END:"
      # End objects
      _, type = line.split ':'
      block = stack.pop
      raise "Ended block type #{type} which wasn't on top #{block.@type}" if block.@type != type

      if stack.empty?
        stack << block
      else
        stack[-1].@children << block
      end
    else
      # Add properties
      key, value = line.split(':', 2)
      raise "Property without active block" if stack.empty?
      stack[-1].@properties << Property.new(key, value)
    end
  end

  raise "Expected 1 block" if stack.size != 1
  vcal = stack[0]
  raise "Not a vcalendar" if vcal.@type != "VCALENDAR"
  return vcal
end

def type_counter(vcal : Block) : Hash(String, UInt128)
  child_type_count = Hash(String, UInt128).new 0

  vcal.@children.each do |child|
    child_type_count[child.@type] += 1
  end

  return child_type_count
end

def filter(ocal : Block, & : String? -> Bool) : Block
  ncal = Block.new ocal.@type
  ocal.@properties.each do |prop|
    ncal.@properties << prop
  end

  ocal.@children.each do |child|
    summary = child["SUMMARY"]?

    if yield summary
      ncal.@children << child.dup
    end
  end

  return ncal
end

def wrap_lines(lines : Array(String), at) : Bytes
  bytes = Array(UInt8).new

  lines.each do |line|
    lbytes = line.bytes

    # yes we can wrap lines inside UTF-8 graphemes, it's not the best but it's
    # mentioned in the the ICAL spec and SHOULD NOT break clients
    # https://datatracker.ietf.org/doc/html/rfc5545#section-3.1
    while lbytes.size > at
      bytes += lbytes[..at - 1]
      bytes += "\r\n ".bytes
      lbytes = lbytes[at..]
    end

    bytes += lbytes
    bytes += "\r\n".bytes
  end

  return array_to_slice bytes
end

def to_ics_lines(cal : Block) : Array(String)
  lines = Array(String).new

  lines << "BEGIN:#{cal.@type}"

  cal.@properties.each do |prop|
    lines << "#{prop.@key}:#{prop.@value}"
  end

  cal.@children.each do |child|
    lines += to_ics_lines(child)
  end

  lines << "END:#{cal.@type}"

  return lines
end

def to_ics(cal : Block) : Bytes
  return wrap_lines(to_ics_lines(cal), 75)
end

# TODO: turn these into real tests
# puts "<<#{String.new wrap_lines(["aaaabbbbccccdddd"], 4)}>>"
# puts "<<#{String.new wrap_lines(["aaaabbbbccccddd"], 4)}>>"
# puts "<<#{String.new wrap_lines(["aaaabbbbccccdddde"], 4)}>>"
# puts "<<#{String.new wrap_lines([""], 4)}>>"

def process_ics(url : String, includes : Array(String), excludes : Array(String), default : Bool, case_insensitive : Bool) : Bytes
  STDERR.puts "# Reading source"

  # File.open("basic.ics") do |io|
  retrieve(url) do |io|

    # Parse data
    ocal = parse_io io

    # Apply filter
    if case_insensitive
      includes = includes.map &.upcase
      excludes = excludes.map &.upcase
    end

    ncal = filter ocal do |summary|
      if case_insensitive && !summary.nil?
        summary = summary.upcase
      end

      if summary.nil?
        default
      elsif includes.any? { |x| summary.includes? x }
        true
      elsif excludes.any? { |x| summary.includes? x }
        false
      else
        default
      end
    end

    STDERR.puts "Filtered ical:"
    STDERR.puts type_counter ncal

    STDERR.puts "# Converting back"
    nics = to_ics ncal

    STDERR.puts "# Done"
    return nics
  end
end

class RealIPPatcher
  include HTTP::Handler

  def call(context)
    req = context.request

    real_ip = req.headers["X-Real-IP"]?
    if !real_ip.nil?
      # port is required but ignored in this context
      req.remote_address = Socket::IPAddress.new(real_ip, 0)
    end

    call_next(context)
  end
end


class CalendarHandler
  include HTTP::Handler

  def initialize(@upstream : String) end

  def call(context)
    # check path
    req = context.request

    if req.path != "/"
      return call_next context
    end


    # get params
    params = req.query_params

    includes = params.fetch_all "include"
    excludes = params.fetch_all "exclude"
    default = params.fetch("default", "true").upcase == "TRUE"
    case_insensitive = params.fetch("insensitive", "true").upcase == "TRUE"

    # process ics
    ics = process_ics(@upstream, includes, excludes, default, case_insensitive)

    # form response
    res = context.response

    # disable caching
    res.headers["Cache-Control"] = "no-cache, no-store, max-age=0, must-revalidate"
    res.headers["Pragma"] = "no-cache"
    res.headers["Expires"] = "Thu, 01 Jan 1970 00:00:00 UTC"

    res.content_type = "text/calendar; charset=utf-8"
    res.write ics
  end
end


# Parse arguments etc

def main()
  server = false
  port = 8080
  upstream = ""
  test = false

  OptionParser.parse do |parser|
    parser.on "-s", "--server", "Start webserver" do
      server = true
    end

    parser.on "-p PORT", "--port=PORT", "Webserver port" do |_port|
      port = _port.to_i
    end

    parser.on "-u UPSTREAM", "--upstream=UPSTREAM", "Upstream URL" do |_upstream|
      upstream = _upstream
    end

    parser.on "-t", "--test", "Run test before doing anything else" do
      test = true
    end
  end

  raise "No upstream" if upstream == ""

  if test
    # Just checking that everything still works
    process_ics(upstream, [] of String, [] of String, true, false)
  end

  if server
    # Booting webserver
    serv = HTTP::Server.new [
      HTTP::ErrorHandler.new,
      RealIPPatcher.new,
      HTTP::LogHandler.new,
      HTTP::CompressHandler.new,
      CalendarHandler.new(upstream),
    ]

    addr = serv.bind_tcp port
    puts "Listening on http://#{addr}"
    serv.listen
  end

  if !test && !server
    raise "Nothing to do"
  end
end

main
