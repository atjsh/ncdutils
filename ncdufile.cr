# SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
# SPDX-License-Identifier: AGPL-3.0-only
require "bit_array"

module NcduFile

  @[Link("libzstd")]
  lib ZSTD
    fun decompress = ZSTD_decompress(dst: UInt8*, dstCapacity: LibC::SizeT, src: UInt8*, compressedSize: LibC::SizeT) : LibC::SizeT
    fun getFrameContentSize = ZSTD_getFrameContentSize(src: UInt8*, srcSize: LibC::SizeT) : LibC::ULongLong
  end

  # Block header/footer
  struct Hdr
    @raw : UInt32

    TYPE_SHIFT = 28
    LEN_MASK = (1<<TYPE_SHIFT) - 1

    def initialize(@raw)
    end

    def self.from_io(io, format)
      new io.read_bytes UInt32, IO::ByteFormat::BigEndian
    end

    def len
      (@raw & LEN_MASK).to_i32
    end

    def type
      @raw >> TYPE_SHIFT
    end

    def data?
      type == 0
    end

    def index?
      type == 1
    end

    def to_s(io)
      @raw.to_s io, 16
    end
  end

  # Index pointer
  struct Ptr
    @raw : UInt64

    OFFSET_SHIFT = 24
    LEN_MASK = (1<<OFFSET_SHIFT) - 1

    def initialize(@raw)
    end

    def initialize(offset, len)
      @raw = (offset.to_u64 << OFFSET_SHIFT) + len
    end

    def self.from_io(io, format)
      new io.read_bytes UInt64, IO::ByteFormat::BigEndian
    end

    def len
      (@raw & LEN_MASK).to_i32
    end

    def offset
      @raw >> OFFSET_SHIFT
    end

    def empty?
      @raw == 0
    end

    def to_s(io)
      @raw.to_s io, 16
    end
  end

  # Absolute Itemref
  struct Ref
    property raw : UInt64

    BLOCK_SHIFT = 24
    OFFSET_MASK = (1<<BLOCK_SHIFT) - 1

    def initialize(@raw)
    end

    def initialize(block, offset)
      @raw = (block.to_u64 << BLOCK_SHIFT) + offset
    end

    def self.from_io(io, format)
      new io.read_bytes UInt64, IO::ByteFormat::BigEndian
    end

    def offset
      (raw & OFFSET_MASK).to_i32
    end

    def block
      raw >> BLOCK_SHIFT
    end

    def to_s(io)
      io << "i#"
      raw.to_s io, 16, precision: 10
    end
  end


  # Custom CBOR parser. I know, I know, there exists a crystal-cbor shard, but
  # that one doesn't make it easy to validate the various constraints I
  # documented for the Item encoding.
  # This is an ugly parser, but ought to be conforming to the spec.  I've
  # only tested this against ncdu's output so far, though, so it's pretty
  # much guaranteed to have bugs. :(
  class CborReader
    getter offset : Int32

    enum Major : UInt8
      PosInt; NegInt; Bytes; Text; Array; Map; Tag; Simple
    end

    # Read directly from a slice rather than an IO. Even specializing for
    # IO::Memory turns out to have pretty measurable overhead.
    def initialize(@input : Bytes, @offset : Int32 = 0)
    end

    @[AlwaysInline]
    def con : UInt8
      @input[@offset] # relies on bounds checking to throw an error on unexpected EOF
    ensure
      @offset += 1
    end

    def parse(&)
      stack = [1] of (UInt16 | Major | Nil)
      while !stack.empty?
        last = stack.last
        first = con
        major = Major.new first >> 5
        minor = first & 0x1f
        arg : UInt64 | Nil = nil

        # Parse header byte + value
        case minor
        when 0x00..0x17 then arg = minor.to_u64
        when 0x18 then arg = con.to_u64
        when 0x19 then arg = (con.to_u64 << 8) + con.to_u64
        when 0x1a then arg = (con.to_u64 << 24) + (con.to_u64 << 16) + (con.to_u64 << 8) + con.to_u64
        when 0x1b then arg = (con.to_u64 << 56) + (con.to_u64 << 48) + (con.to_u64 << 40) + (con.to_u64 << 32) + (con.to_u64 << 24) + (con.to_u64 << 16) + (con.to_u64 << 8) + con.to_u64
        when 0x1f
          case major
          when .pos_int?, .neg_int?, .tag?
            raise "Invalid CBOR"
          when .simple?
            raise "Invalid CBOR" if last.is_a? UInt16
          end
        else
          raise "Invalid CBOR"
        end
        raise "Invalid CBOR" if last.is_a? Major && (arg.nil? || last != major)
        next if major.tag?

        # Read text/bytes argument
        data = nil
        if !arg.nil? && (major.text? || major.bytes?)
          data = @input[@offset ... @offset + arg]
          @offset += arg
          raise "Invalid CBOR" if major.text? && !Unicode.valid? data
        end

        yield stack.size, major, arg, data

        # Update parsing state
        if arg.nil? && (major.text? || major.bytes?)
          stack.push major
        elsif (major.array? || major.map?) && (arg.nil? || arg > 0)
          if arg.nil?
            stack.push nil
          else
            raise "Invalid CBOR" if arg >= (1<<15)
            stack.push (major.map? ? arg * 2 : arg).to_u16
          end
        else
          stack.pop if first == 0xff
          loop do
            last = stack.last?
            if last.is_a? UInt16
              stack[-1] = last - 1
              break if last > 1
              stack.pop
            else
              break
            end
          end
        end
      end
    end
  end


  class Item
    property ref : Ref # Ref to current item
    property type : Int32 = ~0
    # Beware: The 'name' points into the read buffer, and said buffer will not
    # be GC'ed as long as the item is alive. For longer-lived items, make sure
    # to call detach() to create a separate allocation.
    property name : Bytes = Bytes.empty # Might not validate as UTF-8
    property prev : Ref?
    property asize : UInt64 = 0
    property dsize : UInt64 = 0
    property dev : UInt64 = 0
    property rderr : Bool?
    property cumasize : UInt64 = 0
    property cumdsize : UInt64 = 0
    property shrasize : UInt64 = 0
    property shrdsize : UInt64 = 0
    property items : UInt64 = 0
    property sub : Ref?
    property ino : UInt64 = 0
    property nlink : UInt32 = 0
    property uid : UInt32?
    property gid : UInt32?
    property mode : UInt16?
    property mtime : UInt64?
    @attached = true

    def initialize(@ref)
    end

    # Wonderfully unhygenic macros to help with field parsing.
    macro m_uint(f, bits=64)
      if major.pos_int? && arg.not_nil! <= UInt{{bits}}::MAX
        item.{{f}} = arg.not_nil!.to_u{{bits}}
      else
        raise "Invalid '#{ {{ f.stringify }} }' field for item #{ref}: #{major} #{arg}"
      end
    end

    macro m_ref(f)
      if major.pos_int?
        item.{{f}} = Ref.new arg.not_nil!
      elsif major.neg_int? && arg.not_nil! < ref.offset
        item.{{f}} = Ref.new ref.block, ref.offset - arg.not_nil! - 1
      else
        raise "Invalid '#{ {{ f.stringify }} }' itemref for item #{ref}: #{major} #{arg}"
      end
    end

    def self.read(parser, ref, warn_unknown_fields = false) : Item
      item = new ref
      key = nil

      parser.parse do |depth, major, arg, data|
        if depth != 2
          raise "Invalid item at #{ref}: #{major}" if depth == 1 && !major.map?
          next # We don't have any fields that support nesting, so can safely skip
        end

        case key
        when .nil?
          if major.pos_int? && arg.not_nil! <= 18
            key = arg.not_nil!.to_i32
          elsif !major.simple? || !arg.nil?
            STDERR.puts "WARNING: Unknown field in item #{ref}: #{major} #{arg} #{data}" if warn_unknown_fields
            key = -1
          end
          next
        when -1
          # skip unknown field
        when 0
          case major
          when .pos_int? then item.type = arg.not_nil! > 3 ? 2 : arg.not_nil!.to_i32
          when .neg_int? then item.type = arg.not_nil! > 3 ? -2 : -(arg.not_nil!.to_i32) - 1
          else raise "Invalid 'type' field for item #{ref}: #{major} #{arg} #{data}"
          end
        when 1
          # 'data' is only defined for definite-length text or byte strings, so testing for that is sufficient
          item.name = data || raise "Invalid 'name' field for item #{ref}: #{major} #{arg}"
        when 2 then m_ref prev
        when 3 then m_uint asize
        when 4 then m_uint dsize
        when 5 then m_uint dev
        when 6
          if major.simple? && (arg == 20 || arg == 21)
            item.rderr = arg == 21
          else
            raise "Invalid 'rderr' field for item #{ref}: #{major} #{arg}"
          end
        when 7 then m_uint cumasize
        when 8 then m_uint cumdsize
        when 9 then m_uint shrasize
        when 10 then m_uint shrdsize
        when 11 then m_uint items
        when 12 then m_ref sub
        when 13 then m_uint ino
        when 14 then m_uint nlink, 32
        when 15 then m_uint uid, 32
        when 16 then m_uint gid, 32
        when 17 then m_uint mode, 16
        when 18 then m_uint mtime
        else abort "Unreachable"
        end

        key = nil
      end
      raise "Missing or empty 'name' for item #{ref}" if item.name == ""
      raise "Missing 'type' for item #{ref}" if item.type == ~0
      # TODO: Validate the presence of optional fields for the wrong type? Ncdu doesn't really care...
      item
    end

    def to_s(io)
      io << ref
      io << "{type=" << type
      io << " prev=" << prev if prev
      io << " asize=" << asize if asize != 0
      io << " dsize=" << dsize if dsize != 0
      io << " dev=" << dev if dev != 0
      io << " rderrr=" << rderr if rderr
      io << " cumasize=" << cumasize if cumasize != 0
      io << " cumdsize=" << cumdsize if cumdsize != 0
      io << " shrasize=" << shrasize if shrasize != 0
      io << " shrdsize=" << shrdsize if shrdsize != 0
      io << " items=" << items if items != 0
      io << " sub=" << sub if sub
      io << " ino=" << ino if ino != 0
      io << " nlink=" << nlink if nlink != 0
      io << " uid=" << uid if uid
      io << " gid=" << gid if gid
      io << " mode=" << mode if mode
      io << " mtime=" << mtime if mtime
      io << " name="
      io.write name
      io << "}"
    end

    def detach
      @name = @name.clone if @attached
      @attached = false
      self
    end
  end


  # Low-ish level binary export file reader
  class Reader
    @file : File
    @path : String
    @index : Slice(Ptr)
    @blocks : Slice(Block)
    @block_counter : UInt64 = 0
    getter size : Int64
    getter root : Ref

    class Block
      property idx : UInt64 = UInt64::MAX
      property last : UInt64 = 0
      property data : Slice(UInt8) = "".to_slice
    end

    def initialize(@path)
      @file = File.new @path
      @file.read_buffering = false
      header = @file.read_string 8
      raise "Unrecognized file type" if header != "\xbfncduEX1"

      # Find the start of the index block
      @file.seek -4, IO::Seek::End
      index_hdr = @file.read_bytes Hdr
      @size = @file.tell
      raise "Invalid index block" if !index_hdr.index? || index_hdr.len < 24 || index_hdr.len & 7 != 0
      @file.seek 0 - index_hdr.len, IO::Seek::End
      index_start = @file.tell

      # Read the index block
      @file.read_buffering = true
      raise "Invalid index block" if index_hdr != @file.read_bytes Hdr
      @index = Slice(Ptr).new(((index_hdr.len - 16)>>3).to_i32, read_only: true) do |i|
        ptr = @file.read_bytes Ptr
        raise "Invalid pointer at index #{i} (#{ptr})" if !ptr.empty? && (ptr.len <= 12 || ptr.offset >= index_start - 12)
        ptr
      end
      @root = @file.read_bytes Ref
      @file.read_buffering = false

      @blocks = Slice(Block).new 8 { Block.new }
    end

    def dup
      # Crystal std doesn't seem to expose dup(). It does have dup2(), but unsure how to use that.
      File.new @path
    end

    def close
      @file.close
    end

    def read_block(idx)
      raise "Invalid block index #{idx}" if idx >= @index.size || @index[idx].empty?
      @file.seek @index[idx].offset + 8, IO::Seek::Set
      compressed = @file.read_string @index[idx].len - 12
      len = ZSTD.getFrameContentSize compressed.to_unsafe, compressed.bytesize
      raise "Invalid decompressed size for block #{idx} (#{len})" if len <= 0 || len >= (1<<24)
      data = Pointer(UInt8).malloc len
      ret = ZSTD.decompress data, len, compressed.to_unsafe, compressed.bytesize
      raise "Error decompressing block #{idx}: #{ret}" if ret != len
      Slice(UInt8).new data, len, read_only: true
    end

    # read_block() but with an LRU cache, works the same as ncdu's bin_reader
    # because I lack creativity.
    def get_block(idx)
      block = @blocks[0]
      @block_counter += 1
      @blocks.each_with_index do |b, i|
        if b.idx == idx
          b.last = @block_counter
          return b.data
        elsif block.last > b.last
          block = b
        end
      end
      block.idx = idx
      block.last = @block_counter
      block.data = read_block idx
      block.data
    end

    def get_item(ref : Ref)
      data = get_block ref.block
      p = CborReader.new data, ref.offset
      Item.read p, ref
    end

    class ValidateOpts
      property list_blocks : Bool = false
      property list_items : Bool = false
      property warn_unknown_blocks : Bool = true
      property warn_unknown_fields : Bool = true
      property warn_multiple_refs : Bool = true
      property warn_unref : Bool = true
      # TODO: warn_multiple_refs and warn_unref are not actually sufficient to
      # detect cycles or items that are unreachable from the root: it's
      # possible to construct a loop that is unconnected to the main tree. On
      # the upside, such a loop will never be reached by ncdu and (most likely)
      # other tools, so that seems harmless. On the other hand, there are
      # legitimate use cases for having both unreferenced items and multiple
      # references: COW-based tree mutation. It might be nice to have a loop
      # detector that works for such files as well.
    end

    def validate_items(idx, data, items_seen, opts)
      p = CborReader.new data
      while p.offset < data.size
        item = Item.read p, Ref.new(idx, p.offset), opts.warn_unknown_fields
        puts "  #{item}" if opts.list_items
        items_seen.update(item.ref) { |v| v + 1 }

        item.prev.try do |r|
          items_seen.update(r) do |v|
            STDERR.puts "WARNING: Item #{r} is referenced from multiple places (second = #{item.ref}.prev)" if opts.warn_multiple_refs && v > 1
            v | 2
          end
        end

        item.sub.try do |r|
          items_seen.update(r) do |v|
            STDERR.puts "WARNING: Item #{r} is referenced from multiple places (second = #{item.ref}.sub)" if opts.warn_multiple_refs && v > 1
            v | 2
          end
        end
      end
    end

    def validate(opts)
      blocks_seen = BitArray.new @index.size
      items_seen = Hash(Ref, UInt8).new 0, 4096 # bits: 1 = item seen, 2 = ref to item seen
      items_seen[root] = 2

      @file.seek 8, IO::Seek::Set
      loop do
        off = @file.tell
        hdr = @file.read_bytes Hdr
        if hdr.index?
          puts "#{off}: Index block, length = #{hdr.len}" if opts.list_blocks
          break # already validated in initialize()
        end

        if !hdr.data?
          puts "#{off}: Unknown block, type = #{hdr.type}, length = #{hdr.len}" if opts.list_blocks
          STDERR.puts "WARNING: Unknown block type #{hdr.type} at offset #{off} (length = #{hdr.len})" if opts.warn_unknown_blocks
          raise "Invalid data block length at offset #{off} (#{hdr.len})" if hdr.len < 8
          @file.seek hdr.len - 8, IO::Seek::Current
          foot = @file.read_bytes Hdr
          raise "Block at offset #{off} has mismatched header/footer (#{hdr} vs. #{foot})" if hdr != foot
          next
        end

        # data block
        raise "Invalid data block length at offset #{off} (#{hdr.len})" if hdr.len <= 12
        idx = @file.read_bytes UInt32, IO::ByteFormat::BigEndian
        raise "Data block #{idx} at offset #{off} is not listed in the index" if idx >= @index.size
        idxptr = Ptr.new off, hdr.len
        raise "Data block #{idx} at offset #{off} has invalid index pointer (expected #{idxptr} got #{@index[idx]})" if idxptr != @index[idx]
        data = read_block idx
        puts "#{off}: Data block #{idx}, length = #{hdr.len}, uncompressed size = #{data.size}" if opts.list_blocks

        # Assumption: file position is at the end of the data after read_block()
        foot = @file.read_bytes Hdr
        raise "Block at offset #{off} has mismatched header/footer (#{hdr} vs. #{foot})" if hdr != foot
        blocks_seen[idx] = true
        validate_items idx, data, items_seen, opts
      end

      @index.each_with_index do |ptr, i|
        raise "Data block #{i} not found in the file, but the index lists it at #{ptr}" if !ptr.empty? && !blocks_seen[i]
      end
      items_seen.each do |ref, v|
        STDERR.puts "WARNING: No reference found to item #{ref}" if opts.warn_unref && v == 1
        raise "Invalid reference found to #{ref}" if v == 2
      end
    end
  end


  class Listing
    include Iterator(Item)

    def initialize(@reader : Reader, @next : Ref?)
    end

    def next
      if @next.nil?
        stop
      else
        item = @reader.get_item @next.not_nil!
        @next = item.prev
        item
      end
    end
  end


  # Higher-level virtual filesystem API.
  # TODO: Add filtering and sorting options
  class Browser
    getter reader : Reader
    getter root : Item
    # Responsibility of the caller to use this correctly.
    property lock : Mutex

    def initialize(path : String)
      @reader = Reader.new path
      @lock = Mutex.new
      @root = @reader.get_item(@reader.root).detach
    end

    def list(ref : Ref)
      Listing.new @reader, ref
    end

    class Parents
      property stack : Array(Item)

      def initialize
        @stack = [] of Item
      end

      def push(item)
        stack.push item.detach
      end

      def to_s(io)
        return if stack.empty?
        io.write stack[0].name
        stack[1..].each do |i|
          io.write_byte 47
          io.write i.name
        end
      end

      def to_s(io, subname)
        io << self
        io.write_byte 47 if !stack.empty?
        io.write subname
      end
    end

    # yields Parents, Item
    # Parents is modified in-place as directories are traversed.
    def walk(&)
      parents = Parents.new
      yield parents, root
      stack = [] of Listing
      stack.push list root.sub.not_nil! if root.sub
      parents.push root
      while !stack.empty?
        item = stack[-1].next
        if item.is_a?(Iterator::Stop)
          stack.pop
          parents.stack.pop
        else
          yield parents, item
          if !item.sub.nil?
            parents.push item
            stack.push list item.sub.not_nil!
          end
        end
      end
    end

    # TODO: Memoize/cache
    # TODO: This function assumes that non-root item names don't contain a '/'.
    #   This is always true for ncdu-generated exports, but ncdu itself handles
    #   '/' in names just fine and I expect multi-argument scans to make use of
    #   that, if I ever get to implementing that feature.
    def resolve(path)
      parents = [root] of Item
      path.each_part do |name|
        next if name == "" || name == "/"
        sub = parents.last.sub || return nil
        found = false
        list(sub).each do |item|
          if item.name == name.to_slice
            parents.push item.detach
            found = true
            break
          end
        end
        return nil unless found
      end
      parents
    end
  end
end
