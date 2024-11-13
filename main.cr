# SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
# SPDX-License-Identifier: AGPL-3.0-only
require "option_parser"
require "http/server"

require "./ncdufile"
require "./web"


class Cli
  enum Cmd
    None
    Find
    Validate
    Web
    WebUpload
  end

  property parser : OptionParser
  property cmd = Cmd::None
  property input_file = ""
  property validate_opts = NcduFile::Reader::ValidateOpts.new
  property bind_address = "tcp://127.0.0.1:3000"
  property upload_path = "."

  def arg_input_file
    parser.unknown_args do |args|
      STDERR.puts "Missing file name." if args.size == 0
      STDERR.puts "Too many file names." if args.size > 1
      exit if args.size != 1
      @input_file = args[0]
    end
  end

  def initialize
    @parser = OptionParser.new
    parser.banner = "Usage: ncdutils [command]"
    parser.on("-h", "--help", "Show this help") do
      puts parser
      exit
    end
    parser.on("find", "List files") do
      @cmd = Cmd::Find
      # TODO: Filtering & output options
      arg_input_file
    end
    parser.on("validate", "Validate binary export file") do
      @cmd = Cmd::Validate
      parser.banner = "Usage: ncdutils validate <file>"
      parser.on("--list-blocks", "Print a listing of all blocks") { validate_opts.list_blocks = true }
      parser.on("--list-items", "Print a listing of all items") { validate_opts.list_items = true }
      parser.on("--ignore-unknown-blocks", "Disable warnings about unknown blocks") { validate_opts.warn_unknown_blocks = false }
      parser.on("--ignore-unknown-fields", "Disable warnings about unknown item fields") { validate_opts.warn_unknown_fields = false }
      parser.on("--ignore-multiple-refs", "Disable warnings about items being referenced multiple times") { validate_opts.warn_multiple_refs = false }
      parser.on("--ignore-unref", "Disable warnings about unreferenced items") { validate_opts.warn_unref = false }
      arg_input_file
    end
    parser.on("web", "Spawn a web server to browse the file") do
      @cmd = Cmd::Web
      parser.banner = "Usage: ncdutils web <file>"
      parser.on("--bind=ADDR", "Bind to the given address") { |s| @bind_address = s }
      arg_input_file
    end
    parser.on("web-upload", "Spawn a web server that allows export uploads") do
      @cmd = Cmd::WebUpload
      parser.banner = "Usage: ncdutils web-upload <file>"
      parser.on("--bind=ADDR", "Bind to the given address") { |s| @bind_address = s }
      parser.on("--storage=PATH", "Where to store uploaded exports") { |s| @upload_path = s }
    end
    parser.unknown_args do |args|
      next if args.size == 0
      STDERR.puts "ERROR: Unknown option '#{args[0]}'."
      STDERR.puts parser
      exit 1
    end
    parser.parse
  end
end

STDOUT.flush_on_newline = false

cli = Cli.new

case cli.cmd
when .none?
  STDERR.puts cli.parser
  exit 1

when .find?
  f = NcduFile::Browser.new cli.input_file
  f.walk do |parents, item|
    begin
      parents.to_s STDOUT, item.name
      STDOUT.write_byte 10
    rescue
      exit 0
    end
  end

when .validate?
  begin
    f = NcduFile::Reader.new cli.input_file
    f.validate cli.validate_opts
  rescue ex
    STDERR.puts ex.message
    exit 1
  end

when .web?
  f = NcduFile::Browser.new cli.input_file
  s = HTTP::Server.new { |ctx| NcduWeb.serve "/", f, ctx }
  s.bind cli.bind_address
  puts "Listening on #{cli.bind_address}"
  s.listen

when .web_upload?
  Dir.cd cli.upload_path
  w = NcduWebUpload.new
  s = HTTP::Server.new { |ctx| w.serve ctx }
  s.bind cli.bind_address
  puts "Serving #{cli.upload_path}"
  puts "Listening on #{cli.bind_address}"
  s.listen

end
