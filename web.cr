# SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
# SPDX-License-Identifier: AGPL-3.0-only

class NcduWeb
  getter req : HTTP::Request
  getter res : HTTP::Server::Response
  getter file : NcduFile::Browser

  def initialize(@file, ctx)
    @req = ctx.request
    @res = ctx.response
  end

  # TODO: HTML.escape alternative for paths, to better display non-UTF8 or special characters

  def listing(ref)
    # TODO:
    # - Sort options
    # - item type / flags
    # - asize?
    # - extended info?
    # - Pagination / result limit?
    if ref.nil?
      res << "<p><em>Directory empty</em></p>"
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

    res << %{
      <table class=\"listing\">
      <thead><tr>
        <td class="num">Size</td>}
    res << %{<td class="num">Shr</td>} if hasshr
    res << %{<td class="num">Num</td>} if hasnum
    res << %{<td>Name</td>
      </tr></thead><tbody>}

    list.each do |item|
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
      HTML.escape item.name, res
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
      res << "<span>/</span>" if i > 0
      if i+1 != path.size
        res << "<a href=\""
        (path.size-i-1).times { res << "../" }
        res << "\">"
      end
      HTML.escape item.name, res
      res << "</a>" if i+1 != path.size
    end
    res << "</nav>"
  end

  def render(path)
    res << "<!DOCTYPE html>\n"
    res << "<html><head><title>Ncdu » /"
    path[1..].each_with_index do |item, i|
      res << "/" if i > 0
      HTML.escape item.name, res
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
        table { margin: 5px; border-collapse: collapse }
        td { padding: 1px 5px }
        thead { font-weight: bold }

        header { border-bottom: 3px solid #ccc }
        h1 { font-weight: bold }

        nav { padding: 2px 10px; background: #ddd; font-weight: bold }
        nav span { padding: 0 3px }

        .listing { width: 100% }
        .listing tbody tr:hover { background: #eee }
        .num { text-align: right; white-space: nowrap; }
        tbody .num { font-family: monospace; width: 1px }
        .file { color: #000 }
      </style></head>
      <body>
      <header><h1>Ncdu Browser</h1></header>
      <main>}
    parents path
    # TODO: item info
    listing path.last.sub if path.last.type == 0
    res << "</main></body></html>"
  end

  def self.serve(file, ctx)
    c = new file, ctx
    c.res.content_type = "text/html; charset=utf8"
    c.res.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'"
    path = file.resolve Path.posix URI.decode c.req.path
    if path
      c.render path
    else
      c.res.status = HTTP::Status::NOT_FOUND
      c.res.content_type = "text/plain"
      c.res << "404 Page Not Found"
    end
  end
end
