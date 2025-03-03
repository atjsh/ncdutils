# SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
# SPDX-License-Identifier: AGPL-3.0-only

class NcduWeb
  getter req : HTTP::Request
  getter res : HTTP::Server::Response
  getter file : NcduFile::Browser

  MAX_LISTING = 10_000

  def initialize(@prefix : String, @file, ctx)
    @req = ctx.request
    @res = ctx.response
  end

  def print_chr(b, tags = true)
    res << "<em>" if tags
    res << "\\x"
    res.write_byte ((b>>4) < 10 ? 48_u8 : 87_u8) + (b>>4)
    res.write_byte ((b&0xf) < 10 ? 48_u8 : 87_u8) + (b&0xf)
    res << "</em>" if tags
  end

  def print_name(name, tags = true)
    res << %{<span class="name">} if tags
    r = Char::Reader.new String.new name
    while r.has_next?
      if r.error
        print_chr name[r.pos], tags
      else
        c = r.current_char
        case c
        when '&' then res << "&amp;"
        when '<' then res << "&lt;"
        when '>' then res << "&gt;"
        when '\0'..'\u001f', '\u007f' then print_chr c.ord.to_u8, tags
        else res << c
        end
      end
      r.next_char
    end
    res << "</span>" if tags
  end

  def print_flags(item)
    case item.type
    when -4
      res << %{<abbr title="Kernel filesystem">^</abbr>}
    when -3
      res << %{<abbr title="Other filesystem">&gt;</abbr>}
    when -2
      res << %{<abbr title="Excluded">&lt;</abbr>}
    when -1
      res << %{<abbr class="error" title="Error reading this entry">!</abbr>}
    when 0
      if item.rderr == true
        res << %{<abbr class="error" title="Error reading directory contents">!</abbr>}
      elsif item.rderr == false
        res << %{<abbr class="error" title="Error reading subdirectory">.</abbr>}
      elsif item.sub.nil?
        res << %{<abbr title="Empty directory">e</abbr>}
      end
    when 2
      res << %{<abbr title="Special file">@</abbr>}
    when 3
      res << %{<abbr title="Hardlink">H[#{item.nlink}]</abbr>}
    end
  end

  def print_mode(mode)
    res << case mode & 0o170000
           when 0o040000 then 'd'
           when 0o100000 then '-'
           when 0o120000 then 'l'
           when 0o010000 then 'p'
           when 0o140000 then 's'
           when 0o020000 then 'c'
           when 0o060000 then 'b'
           else '?' end
    res << (mode & 0o400 > 0 ? 'r' : '-')
    res << (mode & 0o200 > 0 ? 'w' : '-')
    res << (mode & 0o4000 > 0 ? 's' : mode & 0o100 > 0 ? 'x' : '-')
    res << (mode & 0o40 > 0 ? 'r' : '-')
    res << (mode & 0o20 > 0 ? 'w' : '-')
    res << (mode & 0o2000 > 0 ? 's' : mode & 0o10 > 0 ? 'x' : '-')
    res << (mode & 0o4 > 0 ? 'r' : '-')
    res << (mode & 0o2 > 0 ? 'w' : '-')
    res << (mode & 0o1000 > 0 ? (mode & 0o170000 == 0o040000 ? 't' : 'T') : mode & 0o1 > 0 ? 'x' : '-')
  end

  def listing(ref)
    # TODO:
    # - Sort options
    # - asize?
    # - extended info?
    # - Pagination?
    if ref.nil?
      res << "<p>Directory empty.</p>"
      return
    end

    hasshr = false
    hasnum = false
    hasmode = false
    list = file.list(ref).each.map do |item|
      hasshr = true if item.shrdsize > 0
      hasnum = true if item.type == 0
      hasmode = true if !item.mode.nil?
      item.detach
    end.to_a.sort! do |a,b|
      r = (b.type == 0 ? b.cumdsize : b.dsize) <=> (a.type == 0 ? a.cumdsize : a.dsize)
      r = (b.type == 0 ? b.cumasize : b.asize) <=> (a.type == 0 ? a.cumasize : a.asize) if r == 0
      r = a.name <=> b.name if r == 0
      r
    end

    res << "<p>List truncated to the first " << MAX_LISTING.format << " items.</p>" if list.size > MAX_LISTING
    res << %{
      <table class=\"listing\">
      <thead><tr>
        <td class="flags"></td>}
    res << %{<td class="mode">Mode</td>} if hasmode
    res << %{<td class="num">Size</td>}
    res << %{<td class="num">Shr</td>} if hasshr
    res << %{<td class="num">Num</td>} if hasnum
    res << %{<td>Name</td>
      </tr></thead><tbody>}

    list.each_with_index do |item, i|
      break if i >= MAX_LISTING
      res << %{<tr><td class="flags">}
      print_flags item
      res << %{</td>}
      if hasmode
        if mode = item.mode
          res << %{<td class="mode">}
          print_mode mode
          res << "</td>"
        else
          res << "<td></td>"
        end
      end
      res << %{<td class="num">}
      ((item.type == 0 ? item.cumdsize : item.dsize)/1024).format res, decimal_places: 0, only_significant: true
      res << "K</td>"
      if hasshr
        if item.shrdsize > 0
          res << %{<td class="num">}
          (item.shrdsize/1024).format res, decimal_places: 0, only_significant: true
          res << "K</td>"
        else
          res << "<td></td>"
        end
      end
      if hasnum
        if item.type == 0
          res << %{<td class="num">}
          item.items.format res
          res << "</td>"
        else
          res << "<td></td>"
        end
      end
      res << "<td><a "
      res << "class=\"file\" " if item.type != 0
      res << "href=\""
      URI.encode_path res, String.new item.name
      res << '/' if item.type == 0
      res << "\">"
      print_name item.name
      res << "</a>"
      res << '/' if item.type == 0
      res << "</td>"
      res << "</tr>\n"
    end
    res << "</tbody></table>"
  end

  def parents(path)
    res << "<nav>"
    path.each_with_index do |item, i|
      res << %{<span class="sep">} << (i == 1 && path[0].name == "/".to_slice ? "" : "/") << %{</span>} if i > 0
      if i+1 != path.size
        res << "<a href=\"#{@prefix}"
        path[1..i].each do |p|
          URI.encode_path res, String.new p.name
          res << "/"
        end
        res << "\">"
      end
      print_name item.name
      res << "</a>" if i+1 != path.size
    end
    res << "</nav>"
  end

  def print_size(size)
    size.format res
    res << " ("
    # humanize_bytes is variable-length, copy the format from ncdu instead.
    if size < 1000
      res.printf "%5.1f   B", size
    elsif size < 1023949
      res.printf "%5.1f KiB", size / (1<<10)
    elsif size < 1048523572
      res.printf "%5.1f MiB", size / (1<<20)
    elsif size < 1073688136909
      res.printf "%5.1f GiB", size / (1<<30)
    elsif size < 1099456652194612
      res.printf "%5.1f TiB", size / (1u64<<40)
    elsif size < 1125843611847281869
      res.printf "%5.1f PiB", size / (1u64<<50)
    else
      res.printf "%5.1f EiB", size / (1u64<<60)
    end
    res << ")"
  end

  def iteminfo(item)
    res << %{<table class="iteminfo"><tr><td class="ref">#{item.ref}</td><td>} <<
      case item.type
      when -4 then "Excluded (kernfs)"
      when -3 then "Excluded (other filesystem)"
      when -2 then "Excluded (pattern)"
      when -1 then "Read error"
      when 0 then "Directory"
      when 1 then "Regular file"
      when 2 then "Non-regular file"
      when 3 then "Hard link"
      else "Unknown"
      end
    res << %{</td>}
    res << %{<td class="key">Items</td><td>#{item.items.format}</td>} if item.type == 0
    res << %{<td class="key">Links</td><td>#{item.nlink.format}</td>} if item.type == 3
    res << %{</tr><tr><td class="key">Apparent size</td><td class="size">}
    print_size item.asize
    res << %{</td><td class="key">Disk usage</td><td class="size">}
    print_size item.dsize
    res << %{</td></tr>}
    if item.cumasize > 0 || item.cumdsize > 0
      res << %{<tr><td class="keysec">Cumulative</td><td class="size">}
      print_size item.cumasize
      res << %{</td><td class="keysec">Cumulative</td><td class="size">}
      print_size item.cumdsize
      res << %{</td></tr>}
    end
    if item.shrasize > 0 || item.shrdsize > 0
      res << %{<tr><td class="keysec">Shared</td><td class="size">}
      print_size item.shrasize
      res << %{</td><td class="keysec">Shared</td><td class="size">}
      print_size item.shrdsize
      res << %{</td></tr><tr><td class="keysec">Unique</td><td class="size">}
      print_size item.cumasize - item.shrasize
      res << %{</td><td class="keysec">Unique</td><td class="size">}
      print_size item.cumdsize - item.shrdsize
      res << %{</td></tr>}
    end

    if item.mode || item.uid || item.gid
      res << "<tr>"
      if mode = item.mode
        res << %{<td class="key">Mode</td><td class="mode">}
        print_mode mode
        res << "</td>"
      end
      if item.uid || item.gid
        res << %{<td class="key">Owner</td><td>#{item.uid || "-"}:#{item.gid || "-"}</td>}
      end
      res << "</tr>"
    end

    if item.mtime || item.type == 0
      res << %{<tr>}
      if mtime = item.mtime
        res << %{<td class="key">Last modified</td><td>#{ Time.unix mtime }</td>}
      end
      if item.type == 0
        res << %{<td class="key">Device ID</td><td>}
        res.printf "0x%x", item.dev || 0
        res << %{</td>}
      end
      res << %{</tr>}
    end

    if item.type == 3
      res << %{<tr><td class="key">Device ID</td><td>}
      res.printf "0x%x", item.dev || 0
      res << %{</td>}
      if item.type == 3
        res << %{<td class="key">Inode</td><td>}
        res.printf "0x%x", item.ino
        res << %{</td>}
      end
      res << %{</tr>}
    end

    res << "</table>"
  end

  def render(path)
    res << "<!DOCTYPE html>\n"
    res << %{<html><head>
      <meta name="robots" value="noindex, nofollow">
      <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">
      <title>Ncdu » /}
    path[1..].each_with_index do |item, i|
      res << "/" if i > 0
      print_name item.name, false
    end
    res << %{</title><style type="text/css">
        * { font: inherit; color: inherit; border: 0; margin: 0; padding: 0 }
        body { font: 13px sans-serif; margin: 5px; background: #fff; color: #000 }
        a { color: #00c; text-decoration: none }
        a:hover { text-decoration: underline }
        em, .error { color: #c00 }
        .name { white-space: pre-wrap }
        abbr { cursor: pointer; text-decoration: none }
        table { margin: 5px; border-collapse: collapse }
        p { margin: 5px }
        td { padding: 1px 5px }
        thead { font-weight: bold }

        header { border-bottom: 3px solid #ccc; display: flex; justify-content: space-between }
        h1 { font-weight: bold }
        footer { border-top: 1px solid #ccc; font-size: 80%; color: #999; text-align: center; margin: 20px 0 }

        nav { padding: 2px 10px; background: #ddd; font-weight: bold }
        nav .sep { padding: 0 3px }

        .listing { width: 100% }
        .listing tbody tr:hover { background: #eee }
        .flags { white-space: nowrap; width: 1px; font-weight: bold }
        .listing .mode { white-space: nowrap; width: 1px; font-family: monospace }
        .listing .num { text-align: right; white-space: nowrap; }
        .listing tbody .num { font-family: monospace; width: 1px }
        .file { color: #000 }

        .iteminfo { margin: 15px }
        .ref { text-align: right; color: #999; font-family: monospace }
        .key { text-align: right; font-weight: bold; padding-left: 25px }
        .keysec { text-align: right; font-style: italic }
        .size { text-align: right; font-family: monospace; white-space: pre }
        .iteminfo .mode { font-family: monospace }
      </style></head>
      <body>
      <header>
        <h1>Ncdu Export Browser</h1>
        <span>
          <a href="} << @prefix << %{?export.ncdu" download="export.ncdu">export.ncdu</a>
          (} << file.reader.size.humanize_bytes << %{)
          } << (@prefix != "/" ? %{| <a href="/">new upload</a>} : "") << %{
        </span>
      </header>
      <main>}
    parents path
    iteminfo path.last
    listing path.last.sub if path.last.type == 0
    res << "</main><footer>Generated by ncdutils | AGPL-3.0-only</footer></body></html>"
  end

  def handle(rpath)
    path = file.resolve URI.decode rpath
    if path.nil?
      res.respond_with_status 404, "Page not found"
    elsif path[-1].type == 0 && req.path[-1] != '/'
      res.redirect "#{req.path}/"
    elsif path[-1].type != 0 && req.path[-1] == '/'
      res.redirect req.path.rstrip '/'
    else
      res.content_type = "text/html; charset=utf8"
      res.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'"
      render path
    end
  end

  def self.serve(prefix, file, ctx)
    c = new prefix, file, ctx

    # Sorry, if the tree has an actual /robots.txt as a file, this will overshadow it *shrug*.
    if c.req.path == "/robots.txt"
      c.res.content_type = "text/plain"
      c.res << "User-agent: *\nDisallow: /\n"
      return
    end

    path = c.req.path.lchop prefix
    if path == "" && c.req.query == "export.ncdu"
      c.res.content_type = "application/octet-stream"
      c.res.headers["Content-disposition"] = %{attachment; filename="export.ncdu"}
      # Re-open the file so that we don't have to keep the mutex locked during the transfer.
      # TODO: Partial file transfer support might be nice.
      fd = file.reader.dup
      begin
        IO.copy fd, c.res
      ensure
        fd.close
      end
      return
    end

    file.lock.synchronize { c.handle path }
  end
end


class NcduWebUpload
  @lock = Mutex.new
  @files : Slice(Cache)
  @files_counter : UInt64 = 0

  class Cache
    property name : String = ""
    property last : UInt64 = 0
    property file : NcduFile::Browser? = nil
  end

  def initialize(@base_url : String, @ncdu_bin : String)
    @files = Slice(Cache).new 8 { Cache.new }
  end

  def base_url(ctx)
    if @base_url.empty?
      "http://" + (ctx.request.headers["host"]? || "localhost")
    else
      @base_url
    end
  end

  def index(ctx)
    ctx.response.content_type = "text/html; charset=utf8"
    begin
      File.open("index.html") do |f|
        IO.copy f, ctx.response
        return
      end
    rescue
    end

    ctx.response << %{<!DOCTYPE html><html>
      <head>
       <title>Ncdu Export Browser</title>
       <meta name="robots" value="noindex, nofollow">
       <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">
       <style type="text/css">
        * { font: inherit; color: inherit; border: 0; margin: 0; padding: 0 }
        body { font: 15px sans-serif; margin: 5px; background: #fff; color: #000 }
        a { color: #00c; text-decoration: none }
        a:hover { text-decoration: underline }

        header { border-bottom: 3px solid #ccc; display: flex; justify-content: space-between }
        h1, h2 { font-weight: bold; font-size: 120% }

        main { margin: 20px auto; max-width: 700px }
        fieldset { margin: 5px; padding: 10px; border: 1px solid #ccc }
        legend { font-weight: bold }
        input[type=submit] { padding: 3px 5px; background: #eee; border: 1px solid #999 }
        p { margin: 5px 0 }
        pre { padding: 3px 5px; font-family: monospace; background: #eee }
       </style>
      </head>
      <body>
       <header>
        <h1>Ncdu Export Browser</h1>
       </header>
       <main>
        <form method="POST" action="/" enctype="multipart/form-data">
          <h2>Upload file</h2>
         <fieldset>
          <legend>From the browser</legend>
          <input type="file" name="f">
          <input type="submit" value="Upload">
          <p>Supported files: <a href="https://dev.yorhel.nl/ncdu/jsonfmt">.json</a>, .json.zst,
            <a href="https://dev.yorhel.nl/ncdu/binfmt">.ncdu</a></p>
         </fieldset>
         <fieldset>
          <legend>From the command line</legend>
          <pre>ncdu -1eo- | zstd | curl -T- } << base_url(ctx) << %{/</pre>
          <p>Or with ncdu 2.6+:</p>
          <pre>ncdu -1eO- | curl -T- } << base_url(ctx) << %{/</pre>
         </fieldset>
        </form>
        <article>
        </article>
       </main>
      </body></html>}
  end

  def lookup(name)
    return nil unless /^[a-zA-Z0-9_-]+$/.match name
    return nil unless File.exists? name + ".ncdu"

    # Another ad-hoc LRU cache...
    @lock.synchronize do
      cache = @files[0]
      @files_counter += 1
      @files.each_with_index do |f,i|
        if f.name == name
          f.last = @files_counter
          return f.file
        elsif cache.last > f.last
          cache = f
        end
      end
      cache.file.try &.reader.close
      cache.name = name
      cache.file = nil # In case the next line throws
      cache.file = NcduFile::Browser.new name + ".ncdu"
      cache.last = @files_counter
      return cache.file
    end
  end

  def upload_io(ctx, io : IO)
    id = Random::Secure.urlsafe_base64 12 # 16 characters, 96 bits of randomnes
    tmp = id+".tmp"
    begin
      peek = io.peek
      if peek && peek.size >= 8 && peek[0...8] == "\xbfncduEX1".to_slice
        File.write tmp, io
      else
        Process.run command: @ncdu_bin, args: {"-e0f-","-O", tmp}, input: io, output: Process::Redirect::Close, error: Process::Redirect::Inherit
      end
      # See if it looks like a complete .ncdu file
      f = NcduFile::Browser.new tmp
      f.reader.close
      File.rename tmp, id+".ncdu"
      return id
    rescue e
      STDERR.puts "Invalid upload (#{e})"
      File.delete? tmp
      return nil
    end
  end

  def upload_put(ctx)
    id = upload_io ctx, ctx.request.body.not_nil!
    ctx.response.content_type = "text/plain"
    if id
      ctx.response << "Upload complete! Browse the results at:\n#{base_url ctx}/#{id}/\n"
    else
      ctx.response << "Invalid format or upload error.\n"
    end
  end

  def upload_post(ctx)
    id = nil
    HTTP::FormData.parse(ctx.request) do |part|
      id = upload_io ctx, part.body if part.name == "f"
    end
    if id
      ctx.response.redirect "/#{id}/", :see_other
    else
      ctx.response.respond_with_status :bad_request
    end
  end

  def serve(ctx)
    if ctx.request.path == "/robots.txt"
      ctx.response.content_type = "text/plain"
      ctx.response << "User-agent: *\nDisallow: /\n"
      return
    end

    # For 'curl -T', path can be anything
    if ctx.request.method == "PUT"
      upload_put ctx
      return
    end

    if ctx.request.path == "/"
      if ctx.request.method == "POST"
        upload_post ctx
      else
        index ctx
      end
      return
    end

    name, sep, _ = ctx.request.path.lstrip('/').partition '/'
    file = lookup name
    if file.nil?
      ctx.response.respond_with_status 404, "Page not found"
    elsif sep.empty?
      ctx.response.redirect "/#{name}/"
    else
      NcduWeb.serve "/#{name}/", file, ctx
    end
  end
end
