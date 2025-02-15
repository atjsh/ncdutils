# SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
# SPDX-License-Identifier: AGPL-3.0-only
require "option_parser"
require "http/server"

require "./ncdufile"
require "./web"

# Insert new struct for grouping
struct GroupData
  property count : UInt32
  property total_size : UInt64

  def initialize(@count : UInt32, @total_size : UInt64)
  end
end

# Insert new class for grouping items with details
class GroupInfo
  property count : UInt32
  property total_size : UInt64
  property items : Array({String, UInt64})
  def initialize(@count : UInt32, @total_size : UInt64, @items : Array({String, UInt64}))
  end
end

class Cli
  enum Cmd
    None
    Find
    Validate
    Web
    WebUpload
    Cleanup  # renamed command to cover multiple directories
    Freq      # added new command for frequency
    Largest   # new command to show top largest files
  end

  property parser : OptionParser
  property cmd = Cmd::None
  property input_file = ""
  property validate_opts = NcduFile::Reader::ValidateOpts.new
  property bind_address = "tcp://127.0.0.1:3000"
  property base_url = ""
  property ncdu_bin = "ncdu"
  property cleanup_dirs = [
    # dev directories
    "node_modules",
    "bower_components",
    "dist",
    "build",
    "__pycache__",
    "target",
    "venv",      # virtual environment directories (Python)
    ".venv",
    ".git",      # git directories
    ".svn",      # subversion directories
    "egg-info",  # Python package metadata
    "coverage"   # code coverage reports

    # windows-related directories that can be cleaned up
    # should keep user data directories like "AppData/Local" and "Program Files"
    # delete directories like temp, cache, logs, etc.

    
    # mac directories that can be cleaned up
  ] of String  # expanded list of unnecessary directories
  property cleanup_path_only : Bool = false    # new property for cleanup output mode
  property largest_path_only : Bool = false

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
      parser.on("--base-url=URL", "URL to access this server") { |s| @base_url = s }
      parser.on("--ncdu-bin=PATH", "(Absolute) path to the ncdu binary") { |s| @ncdu_bin = s }
    end
    parser.on("cleanup", "List unnecessary directories") do
      @cmd = Cmd::Cleanup
      arg_input_file
      parser.on("--dir=NAME", "Additional directory name to cleanup (can be used multiple times)") do |name|
        cleanup_dirs << name
      end
      parser.on("--path-only", "Print only the path for cleanup results") { @cleanup_path_only = true }
    end
    parser.on("freq", "Show most frequent directory name (frequency >= 100)") do
      @cmd = Cmd::Freq
      arg_input_file
    end
    parser.on("largest", "Show top 100 largest single files") do
      @cmd = Cmd::Largest
      arg_input_file
      parser.on("--path-only", "Print only the path for largest results") { @largest_path_only = true }
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
  browser = NcduFile::Browser.new(cli.input_file)
  browser.walk do |parents, item|
    begin
      parents.to_s STDOUT, item.name
      STDOUT.write_byte 10
    rescue
      exit 0
    end
  end

when .validate?
  begin
    reader = NcduFile::Reader.new(cli.input_file)
    reader.validate(cli.validate_opts)
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
  w = NcduWebUpload.new cli.base_url, cli.ncdu_bin
  s = HTTP::Server.new { |ctx| w.serve ctx }
  s.bind cli.bind_address
  puts "Serving current directory"
  puts "Listening on #{cli.bind_address}"
  s.listen

when .cleanup?
  browser = NcduFile::Browser.new(cli.input_file)
  entries = [] of {String, UInt64}
  browser.walk do |parents, item|
    if cli.cleanup_dirs.includes?(String.new(item.name)) && item.type == 0
      # Build full path using parents
      path = ""
      parents.each do |p|
        path = path.empty? ? String.new(p.name) : path + "/" + String.new(p.name)
      end
      path += "/" + String.new(item.name)
      # Skip paths containing "AppData/Local", "Program Files", or match 'Users/(any)/AppData/Roaming'
      if path.includes?("AppData/Local") || path.includes?("Program Files") || (path.match(%r|Users/[^/]+/AppData/Roaming|) != nil)
        next
      end
      size = item.cumdsize
      entries << {path, size}
    end
  end
  entries.sort_by! { |e| -(e[1].to_i64) }
  
  if cli.cleanup_path_only
    # Print only the paths, one per line.
    entries.each do |entry|
      puts entry[0]
    end
  else
    total = entries.reduce(0_u64) { |sum, e| sum + e[1] }
    # Group entries by their directory name (last component) and collect details
    groups = Hash(String, GroupInfo).new
    entries.each do |entry|
      dir_name = entry[0].split("/")[-1]
      if groups.has_key?(dir_name)
        groups[dir_name].count += 1
        groups[dir_name].total_size += entry[1]
        groups[dir_name].items << entry
      else
        groups[dir_name] = GroupInfo.new(1_u32, entry[1], [entry])
      end
    end

    # Updated human-friendly lambda for disk size
    hr_size = ->(size : UInt64) {
      if size < 1024
        "#{size}B"
      elsif size < 1024 * 1024
        val = size.to_f / 1024
        val == val.to_i ? "#{val.to_i}KB" : "%.1fKB" % val
      elsif size < 1024 * 1024 * 1024
        val = size.to_f / (1024 * 1024)
        val == val.to_i ? "#{val.to_i}MB" : "%.1fMB" % val
      else
        val = size.to_f / (1024 * 1024 * 1024)
        val == val.to_i ? "#{val.to_i}GB" : "%.1fGB" % val
      end
    }

    # Print summary of each group along with all items
    groups.each do |name, group|
      puts "#{name} - count: #{group.count}, total size: #{hr_size.call(group.total_size)}"
      group.items.each do |item|
        puts "   #{item[0]} - #{hr_size.call(item[1])}"
      end
    end

    # Print overall total
    puts "Total: #{hr_size.call(total)}"
  end

when .freq?
  browser = NcduFile::Browser.new(cli.input_file)
  # Create hash with default {count, disk} to avoid missing key errors
  folder_stats = Hash(String, {UInt32, UInt64}).new { {0_u32, 0_u64} }
  browser.walk do |parents, item|
    if item.type == 0
      key = String.new(item.name)
      count, total = folder_stats[key]
      folder_stats[key] = { count + 1_u32, total + item.cumdsize }
    end
  end
  filtered = folder_stats.select { |_, stat| stat[0] >= 100 }
  if filtered.empty?
    puts "No directory with frequency >= 100 found"
  else
    # Define human-friendly size lambda as before
    hr_size = ->(size : UInt64) {
      if size < 1024
        "#{size}B"
      elsif size < 1024 * 1024
        val = size.to_f / 1024
        val == val.to_i ? "#{val.to_i}KB" : "%.1fKB" % val
      elsif size < 1024 * 1024 * 1024
        val = size.to_f / (1024 * 1024)
        val == val.to_i ? "#{val.to_i}MB" : "%.1fMB" % val
      else
        val = size.to_f / (1024 * 1024 * 1024)
        val == val.to_i ? "#{val.to_i}GB" : "%.1fGB" % val
      end
    }
    # Sorted by frequency (descending)
    sorted_by_freq = filtered.to_a.sort_by { |_, stat| -stat[0].to_i64 }[0, 100]
    grand_total_freq = sorted_by_freq.reduce(0_u64) { |sum, (_, stat)| sum + stat[1] }
    # Sorted by disk size (descending)
    sorted_by_disk = filtered.to_a.sort_by { |_, stat| -stat[1].to_i64 }[0, 100]
    grand_total_disk = sorted_by_disk.reduce(0_u64) { |sum, (_, stat)| sum + stat[1] }
    
    puts "=== Sorted by Frequency ==="
    sorted_by_freq.each do |dir, stat|
      puts "#{dir} (frequency: #{stat[0]}, total disk: #{hr_size.call(stat[1])})"
    end
    puts "Grand total disk usage (by frequency): #{hr_size.call(grand_total_freq)}"
    
    puts "\n=== Sorted by Disk Size ==="
    sorted_by_disk.each do |dir, stat|
      puts "#{dir} (frequency: #{stat[0]}, total disk: #{hr_size.call(stat[1])})"
    end
    puts "Grand total disk usage (by disk size): #{hr_size.call(grand_total_disk)}"
  end

when .largest?
  browser = NcduFile::Browser.new(cli.input_file)
  files = [] of {String, UInt64}
  browser.walk do |parents, item|
    # item.type == 0 is directory, so collect all others as "file"
    if item.type != 0
      path = ""
      parents.each do |p|
        path = path.empty? ? String.new(p.name) : path + "/" + String.new(p.name)
      end
      path += "/" + String.new(item.name)
      files << {path, item.asize}
    end
  end
  files.sort_by! { |x| -x[1].to_i64 }
  hr_size = ->(size : UInt64) {
    if size < 1024
      "#{size}B"
    elsif size < 1024 * 1024
      val = size.to_f / 1024
      val == val.to_i ? "#{val.to_i}KB" : "%.1fKB" % val
    elsif size < 1024 * 1024 * 1024
      val = size.to_f / (1024 * 1024)
      val == val.to_i ? "#{val.to_i}MB" : "%.1fMB" % val
    else
      val = size.to_f / (1024 * 1024 * 1024)
      val == val.to_i ? "#{val.to_i}GB" : "%.1fGB" % val
    end
  }

  files[0, 100].each do |f|
    if cli.largest_path_only
      puts f[0]
    else
      puts "#{f[0]} (size: #{hr_size.call(f[1])})"
    end
  end

  unless cli.largest_path_only
    total_100 = files[0, 100].reduce(0_u64) { |sum, f| sum + f[1] }
    puts "Total size of top 100: #{hr_size.call(total_100)}"

    ext_groups = Hash(String, {UInt64, UInt32}).new { {0_u64, 0_u32} }
    files[0, 100].each do |f|
      ext = File.extname(f[0])
      ext = ext.empty? ? "noext" : ext
      total_size, count = ext_groups[ext]
      ext_groups[ext] = { total_size + f[1], count + 1_u32 }
    end
    puts "Grouped by extension:"
    ext_groups.each do |ext, (ext_size, ext_count)|
      puts "#{ext} (count: #{ext_count}, total: #{hr_size.call(ext_size)})"
    end
  end
end
