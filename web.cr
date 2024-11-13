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

  def listing(ref)
    # TODO:
    # - Sort options
    # - item type / flags
    # - asize?
    # - extended info?
    # - Pagination?
    if ref.nil?
      res << "<p>Directory empty.</p>"
      return
    end

    hasshr = false
    hasnum = false
    list = file.list(ref).each.map do |item|
      hasshr = true if item.shrdsize > 0
      hasnum = true if item.type == 0
      item.detach
    end.to_a.sort! do |a,b|
      (b.type == 0 ? b.cumdsize : b.dsize) <=> (a.type == 0 ? a.cumdsize : a.dsize)
    end

    res << "<p>List truncated to the first " << MAX_LISTING.format << " items.</p>" if list.size > MAX_LISTING
    res << %{
      <table class=\"listing\">
      <thead><tr>
        <td class="num">Size</td>}
    res << %{<td class="num">Shr</td>} if hasshr
    res << %{<td class="num">Num</td>} if hasnum
    res << %{<td>Name</td>
      </tr></thead><tbody>}

    list.each_with_index do |item, i|
      break if i >= MAX_LISTING
      res << "<tr><td class=\"num\">"
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
      res << %{<span class="sep">/</span>} if i > 0
      if i+1 != path.size
        res << "<a href=\""
        (path.size-i-1).times { res << "../" }
        res << "\">"
      end
      print_name item.name
      res << "</a>" if i+1 != path.size
    end
    res << "</nav>"
  end

  def render(path)
    res << "<!DOCTYPE html>\n"
    res << %{<html><head>
      <meta name="robots" value="noindex, nofollow">
      <title>Ncdu » /}
    path[1..].each_with_index do |item, i|
      res << "/" if i > 0
      print_name item.name, false
    end
    res << "</title><base href=\"" << @prefix
    # The path and file URLs rely on this base; the final '/' is not always
    # included in the request URI but required for the links to work.
    path[1..].each do |item|
      URI.encode_path res, String.new item.name
      res << "/"
    end
    res << %{"><style type="text/css">
        * { font: inherit; color: inherit; border: 0; margin: 0; padding: 0 }
        body { font: 13px sans-serif; margin: 5px; background: #fff; color: #000 }
        a { color: #00c; text-decoration: none }
        a:hover { text-decoration: underline }
        em { color: #c00 }
        .name { white-space: pre-wrap }
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
        .num { text-align: right; white-space: nowrap; }
        tbody .num { font-family: monospace; width: 1px }
        .file { color: #000 }
      </style></head>
      <body>
      <header>
        <h1>Ncdu Export Browser</h1>
        <span>
          <a href="} << @prefix << %{?export.ncdu">export.ncdu</a>
          (} << file.reader.size.humanize_bytes << %{)
          } << (@prefix != "/" ? %{| <a href="/">new upload</a>} : "") << %{
        </span>
      </header>
      <main>}
    parents path
    # TODO: item info
    listing path.last.sub if path.last.type == 0
    res << "</main><footer>Generated by ncdutils | AGPL-3.0-only</footer></body></html>"
  end

  def handle(rpath)
    path = file.resolve Path.posix URI.decode rpath
    if path
      res.content_type = "text/html; charset=utf8"
      res.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'"
      render path
    else
      res.respond_with_status 404, "Page not found"
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
          <pre>ncdu -1o- | zstd | curl -T- } << base_url(ctx) << %{/</pre>
          <p>Or with ncdu 2.6+:</p>
          <pre>ncdu -1O- | curl -T- } << base_url(ctx) << %{/</pre>
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
      ctx.response.redirect "/"+id+"/", :see_other
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

    name, _, _ = ctx.request.path.lstrip('/').partition '/'
    file = lookup name
    if file.nil?
      ctx.response.respond_with_status 404, "Page not found"
    else
      NcduWeb.serve "/"+name+"/", file, ctx
    end
  end
end
