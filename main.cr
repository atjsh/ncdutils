# SPDX-FileCopyrightText: Yoran Heling <projects@yorhel.nl>
# SPDX-License-Identifier: AGPL-3.0-only
require "option_parser"
require "./ncdufile"


enum Cmd
  None
  Validate
end

cmd = Cmd::None
input_file = ""
list_blocks = false
list_items = false
warn_unknown_blocks = true
warn_unknown_fields = true

optparser = OptionParser.new do |parser|
  parser.banner = "Usage: ncdutils [command]"
  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit
  end
  parser.on("validate", "Validate binary export file") do
    cmd = Cmd::Validate
    parser.banner = "Usage: ncdutils validate <file>"
    parser.on("--list-blocks", "Print a listing of all blocks") { list_blocks = true }
    parser.on("--list-items", "Print a listing of all items") { list_items = true }
    parser.on("--ignore-unknown-blocks", "Disable warnings about unknown blocks") { warn_unknown_blocks = false }
    parser.on("--ignore-unknown-fields", "Disable warnings about unknown item fields") { warn_unknown_fields = false }
    parser.unknown_args do |args|
      STDERR.puts "Missing file name." if args.size == 0
      STDERR.puts "Too many file names." if args.size > 1
      exit if args.size != 1
      input_file = args[0]
    end
  end
end

optparser.parse

case
when cmd.none?
  STDERR.puts optparser
when cmd.validate?
  f = NcduFile::Reader.new input_file
  f.validate list_blocks: list_blocks, list_items: list_items, warn_unknown_blocks: warn_unknown_blocks, warn_unknown_fields: warn_unknown_fields
end
