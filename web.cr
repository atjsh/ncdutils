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

  def listing(ref)
    # TODO:
    # - Styling
    # - Sort options
    # - item type / flags
    # - graph
    # - asize
    # - extended info
    if ref.nil?
      res << "<p><em>Directory empty</em></p>"
      return
    end
    res << "<table>"
    file.list(ref).each do |item|
      res << "<tr><td>"
      (item.type == 0 ? item.cumdsize : item.dsize).humanize_bytes res
      res << "</td><td>"
      item.shrdsize.humanize_bytes res if item.shrdsize > 0
      res << "</td><td>"
      if item.type == 0
        res << "<a href=\""
        URI.encode_path res, String.new item.name
        res << "/\">"
      end
      HTML.escape item.name, res
      res << "</a>/" if item.type == 0
      res << "</td>"
      res << "</tr>"
    end
    res << "</table>"
  end

  def parents(path)
    res << "<nav>"
    path.each_with_index do |item, i|
      res << "/" if i > 0
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

  def self.serve(file, ctx)
    c = new file, ctx
    c.res.content_type = "text/html; charset=utf8"
    # TODO: Test special characters and non-utf8 paths
    path = file.resolve Path.posix c.req.path
    if path
      c.parents path
      c.listing path.last.sub
    else
      c.res.status = HTTP::Status::NOT_FOUND
      c.res.content_type = "text/plain"
      c.res << "404 Page Not Found"
    end
  end
end
