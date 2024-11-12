# SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
# SPDX-License-Identifier: AGPL-3.0-only

class NcduWeb
  getter req : HTTP::Request
  getter res : HTTP::Server::Response
  getter file : NcduFile::Browser

  MAX_LISTING = 10_000

  def initialize(@file, ctx)
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
    res << "</title><base href=\"/"
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
          <a href="/?export.ncdu">export.ncdu</a>
          (} << file.reader.size.humanize_bytes << %{)
        </span>
      </header>
      <main>}
    parents path
    # TODO: item info
    listing path.last.sub if path.last.type == 0
    res << "</main></body></html>"
  end

  def handle
    path = file.resolve Path.posix URI.decode req.path
    if path
      res.content_type = "text/html; charset=utf8"
      res.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'"
      render path
    else
      res.status = HTTP::Status::NOT_FOUND
      res.content_type = "text/plain"
      res << "404 Page Not Found"
    end
  end

  def self.serve(file, ctx)
    c = new file, ctx

    # Sorry, if the tree has an actual /robots.txt as a file, this will overshadow it *shrug*.
    if c.req.path == "/robots.txt"
      c.res.content_type = "text/plain"
      c.res << "User-agent: *\nDisallow: /\n"
      return
    end

    if c.req.path == "/" && c.req.query == "export.ncdu"
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

    file.lock.synchronize { c.handle }
  end
end
