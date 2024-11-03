# SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
# SPDX-License-Identifier: AGPL-3.0-only
require "option_parser"
require "./ncdufile"


class Cli
  enum Cmd
    None
    Find
    Validate
  end

  property parser : OptionParser
  property cmd = Cmd::None
  property input_file = ""
  property validate_opts = NcduFile::Reader::ValidateOpts.new

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
    parser.unknown_args do |args|
      next if args.size == 0
      STDERR.puts "ERROR: Unknown option '#{args[0]}'."
      STDERR.puts parser
      exit 1
    end
    parser.parse
  end
end

cli = Cli.new

case cli.cmd
when .none?
  STDERR.puts cli.parser
  exit 1
when .find?
  f = NcduFile::Browser.new cli.input_file
  f.walk do |path, item|
    begin
      puts path
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
end
